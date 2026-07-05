defmodule Sqlites.Backups do
  @moduledoc """
  Backup orchestration: snapshots are taken and uploaded by the
  database's owning node (`Sqlites.DataPlane`), recorded here in the
  control plane's `backups` table. The same code path serves dev and
  prod — only the object-store adapter differs.
  """

  import Ecto.Query

  alias Sqlites.ControlPlane.{Backup, Database}
  alias Sqlites.DataPlane
  alias Sqlites.Repo

  @spec trigger(Database.t()) :: {:ok, Backup.t()} | {:error, term()}
  def trigger(%Database{} = database) do
    backup_id = Ecto.UUID.generate()
    object_key = object_key(database, backup_id)

    with {:ok, %{size_bytes: size_bytes}} <- DataPlane.backup_database(database, object_key) do
      %Backup{
        id: backup_id,
        database_id: database.id,
        object_key: object_key,
        size_bytes: size_bytes
      }
      |> Repo.insert()
    end
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
    |> Enum.each(fn backup -> Sqlites.ObjectStore.delete(backup.object_key) end)

    Backup
    |> where([b], b.database_id == ^database.id)
    |> Repo.delete_all()

    :ok
  end

  defp object_key(%Database{} = database, backup_id) do
    "backups/#{database.tenant_id}/#{database.id}/#{backup_id}.db"
  end
end
