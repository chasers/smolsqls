defmodule Smolsqls.Backups do
  @moduledoc """
  Backup orchestration: snapshots are taken and uploaded by the
  database's owning node (`Smolsqls.DataPlane`), recorded here in the
  control plane's `backups` table. The same code path serves dev and
  prod — only the object-store adapter differs.
  """

  import Ecto.Query

  alias Smolsqls.ControlPlane.{Backup, Database}
  alias Smolsqls.DataPlane
  alias Smolsqls.DataPlane.IdleSnapshots
  alias Smolsqls.Repo

  @spec trigger(Database.t()) :: {:ok, Backup.t()} | {:error, term()}
  def trigger(%Database{} = database) do
    backup_id = Ecto.UUID.generate()
    object_key = object_key(database, backup_id)

    with {:ok, %{size_bytes: size_bytes}} <- DataPlane.backup_database(database, object_key) do
      insert_backup(backup_id, database, object_key, size_bytes, :manual)
    end
  end

  @doc """
  Produces an `:automatic` backup for the daily-backup guarantee,
  choosing the cheapest artifact source:

    * a **hot** database is snapshotted through its live writer
      (`VACUUM INTO`) so the backup reflects current data;
    * a **cold** database with an existing idle snapshot is promoted by
      a server-side object-store copy — no activation;
    * a cold database that has never shipped is activated and
      snapshotted (the rare "never captured" case).
  """
  @spec trigger_automatic(Database.t()) :: {:ok, Backup.t()} | {:error, term()}
  def trigger_automatic(%Database{} = database) do
    backup_id = Ecto.UUID.generate()
    object_key = object_key(database, backup_id)

    with {:ok, %{size_bytes: size_bytes}} <- capture(database, object_key) do
      insert_backup(backup_id, database, object_key, size_bytes, :automatic)
    end
  end

  @doc """
  Active databases whose newest backup is older than `cutoff` (or that
  have never been backed up) — the daily sweep's work list. Databases
  that have never been backed up sort first. `:limit` bounds the batch.
  """
  @spec due_for_backup(DateTime.t(), keyword()) :: [Database.t()]
  def due_for_backup(cutoff, opts \\ []) do
    latest =
      Backup
      |> group_by([b], b.database_id)
      |> select([b], %{database_id: b.database_id, last_backup_at: max(b.inserted_at)})

    query =
      Database
      |> where([d], d.status == :active)
      |> join(:left, [d], l in subquery(latest), on: l.database_id == d.id)
      |> where([d, l], is_nil(l.last_backup_at) or l.last_backup_at < ^cutoff)
      |> order_by([d, l], asc_nulls_first: l.last_backup_at)

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> limit(query, ^limit)
      end

    Repo.all(query)
  end

  @doc """
  SLA stats for the daily-backup guarantee, powering the
  `smolsqls.backup_sla.*` gauges. `in_breach` is the number of active
  databases that have gone longer than `threshold_ms` without a backup;
  a brand-new database gets a full window of grace (its breach is
  measured from creation, not from epoch). `oldest_age_seconds` is the
  age of the worst backup gap across all active databases, treating a
  never-backed-up database as aged from its creation.

  `threshold_ms` is deliberately larger than the sweep's SLA window
  (28h vs 24h): a healthy database's backup age oscillates up to the SLA
  plus one sweep interval, so the breach threshold carries slack to
  avoid flapping at the boundary.
  """
  @spec sla_stats(non_neg_integer()) ::
          %{in_breach: non_neg_integer(), oldest_age_seconds: non_neg_integer()}
  def sla_stats(threshold_ms) do
    now = DateTime.utc_now()
    deadline = DateTime.add(now, -threshold_ms, :millisecond)

    latest =
      Backup
      |> group_by([b], b.database_id)
      |> select([b], %{database_id: b.database_id, last_backup_at: max(b.inserted_at)})

    base =
      Database
      |> where([d], d.status == :active)
      |> join(:left, [d], l in subquery(latest), on: l.database_id == d.id)

    in_breach =
      base
      |> where([d, l], d.inserted_at < ^deadline)
      |> where([d, l], is_nil(l.last_backup_at) or l.last_backup_at < ^deadline)
      |> Repo.aggregate(:count)

    oldest =
      base
      |> select([d, l], min(coalesce(l.last_backup_at, d.inserted_at)))
      |> Repo.one()

    %{in_breach: in_breach, oldest_age_seconds: age_seconds(now, oldest)}
  end

  defp age_seconds(_now, nil), do: 0

  defp age_seconds(now, %DateTime{} = timestamp),
    do: max(DateTime.diff(now, timestamp, :second), 0)

  defp age_seconds(now, %NaiveDateTime{} = timestamp),
    do: age_seconds(now, DateTime.from_naive!(timestamp, "Etc/UTC"))

  defp capture(%Database{} = database, object_key) do
    cond do
      DataPlane.database_hot?(database.id) ->
        DataPlane.backup_database(database, object_key)

      (database.snapshot_generation || 0) > 0 ->
        promote_idle_snapshot(database, object_key)

      true ->
        DataPlane.backup_database(database, object_key)
    end
  end

  defp promote_idle_snapshot(%Database{} = database, object_key) do
    case Smolsqls.ObjectStore.copy(IdleSnapshots.object_key(database), object_key) do
      {:ok, size_bytes} -> {:ok, %{object_key: object_key, size_bytes: size_bytes}}
      {:error, :not_found} -> DataPlane.backup_database(database, object_key)
      {:error, _reason} = error -> error
    end
  end

  defp insert_backup(backup_id, %Database{} = database, object_key, size_bytes, origin) do
    %Backup{
      id: backup_id,
      database_id: database.id,
      object_key: object_key,
      size_bytes: size_bytes,
      origin: origin
    }
    |> Repo.insert()
  end

  @spec list(Database.t()) :: [Backup.t()]
  def list(%Database{id: database_id}) do
    Backup
    |> where([b], b.database_id == ^database_id)
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  @doc """
  Cursor-paginated backup listing, newest first: keyset on
  `(inserted_at, id)` descending, `after` is the id of the last row of
  the previous page. Returns `%{entries: [...], next: id | nil}`.
  """
  @spec paginate(Database.t(), keyword()) ::
          {:ok, %{entries: [Backup.t()], next: String.t() | nil}} | {:error, :invalid_cursor}
  def paginate(%Database{} = database, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    with {:ok, cursor} <- cursor(database, Keyword.get(opts, :after)) do
      entries =
        Backup
        |> where([b], b.database_id == ^database.id)
        |> after_cursor(cursor)
        |> order_by([b], desc: b.inserted_at, desc: b.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      {page, rest} = Enum.split(entries, limit)
      {:ok, %{entries: page, next: if(rest == [], do: nil, else: List.last(page).id)}}
    end
  end

  defp cursor(_database, nil), do: {:ok, nil}

  defp cursor(database, after_id) do
    case get(database, after_id) do
      %Backup{} = cursor -> {:ok, cursor}
      nil -> {:error, :invalid_cursor}
    end
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, %Backup{inserted_at: inserted_at, id: id}) do
    where(
      query,
      [b],
      b.inserted_at < ^inserted_at or (b.inserted_at == ^inserted_at and b.id < ^id)
    )
  end

  @spec get(Database.t(), String.t()) :: Backup.t() | nil
  def get(%Database{id: database_id}, backup_id) do
    case Ecto.UUID.cast(backup_id) do
      {:ok, uuid} ->
        Backup
        |> where([b], b.database_id == ^database_id and b.id == ^uuid)
        |> Repo.one()

      :error ->
        nil
    end
  end

  @spec restore(Database.t(), String.t()) :: :ok | {:error, term()}
  def restore(%Database{} = database, backup_id) do
    case get(database, backup_id) do
      %Backup{object_key: object_key} -> DataPlane.restore_database(database, object_key)
      nil -> {:error, :backup_not_found}
    end
  end

  @spec delete_all(Database.t()) :: :ok
  def delete_all(%Database{} = database) do
    database
    |> list()
    |> Enum.each(fn backup -> Smolsqls.ObjectStore.delete(backup.object_key) end)

    Backup
    |> where([b], b.database_id == ^database.id)
    |> Repo.delete_all()

    :ok
  end

  defp object_key(%Database{} = database, backup_id) do
    "backups/#{database.tenant_id}/#{database.id}/#{backup_id}.db"
  end
end
