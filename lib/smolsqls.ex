defmodule Smolsqls do
  @moduledoc """
  Cross-plane orchestration: operations that must touch the control
  plane, the infra layer, and the data plane in order. Web layers call
  these instead of sequencing the planes themselves.
  """

  require Logger

  alias Smolsqls.ControlPlane
  alias Smolsqls.ControlPlane.{Database, Tenant}
  alias Smolsqls.DataPlane
  alias Smolsqls.Infra

  @spec create_database(Tenant.t(), map()) :: {:ok, Database.t()} | {:error, term()}
  def create_database(%Tenant{} = tenant, attrs) do
    with {:ok, database} <- ControlPlane.create_database(tenant, attrs),
         {:ok, database} <- DataPlane.place_database(database),
         :ok <- Infra.provision(database) do
      {:ok, database}
    end
  end

  @pitr_window_days 30

  @doc """
  Branches `source` into a new independent database, seeded either:

    * **from a snapshot** (default) — the source's latest shipped artifact
      (idle snapshot, else newest backup), server-side copied; or
    * **from a point in time** — when `attrs["timestamp"]` is given, the
      source's litestream replica restored to that instant. Requires the
      source to have litestream enabled and the timestamp within the
      recoverable window (last #{@pitr_window_days} days). A timestamp newer
      than the latest replicated point is clamped to it (so "as of now" on an
      idle database branches the freshest available state); one older than the
      replica's earliest point is rejected. `branch_point_at` records the
      effective (clamped) point, not the requested one.

  Zero impact on the source's writer either way. Creates the child row with
  lineage and places it, restoring the seeded bytes. On a failure after the
  child row is created, the partial branch is cleaned up best-effort.

  Errors: `:no_snapshot`, `:point_in_time_requires_litestream`,
  `:invalid_timestamp`, `:timestamp_out_of_window`.
  """
  @spec branch_database(Database.t(), map()) :: {:ok, Database.t()} | {:error, term()}
  def branch_database(%Database{} = source, attrs) do
    {timestamp, attrs} = Map.pop(attrs, "timestamp")

    with {:ok, seed} <- resolve_seed(source, timestamp),
         attrs = stamp_branch_point(attrs, seed),
         {:ok, child} <- ControlPlane.branch_database(source, attrs),
         {:ok, placed} <- seed_and_place(source, child, seed) do
      {:ok, %{placed | auth_token: child.auth_token}}
    end
  end

  defp resolve_seed(%Database{} = source, nil) do
    with {:ok, key} <- source_snapshot_key(source), do: {:ok, {:snapshot, key}}
  end

  defp resolve_seed(%Database{litestream_enabled: false}, _timestamp) do
    {:error, :point_in_time_requires_litestream}
  end

  defp resolve_seed(%Database{} = source, timestamp) do
    with {:ok, at} <- parse_timestamp(timestamp),
         :ok <- check_window(at),
         {:ok, effective_at} <- clamp_to_replica(source, at) do
      {:ok, {:pitr, effective_at}}
    end
  end

  defp clamp_to_replica(%Database{} = source, %DateTime{} = at) do
    case DataPlane.replica_range(source) do
      {:ok, %{earliest: earliest, latest: latest}} ->
        cond do
          DateTime.compare(at, earliest) == :lt -> {:error, :timestamp_out_of_window}
          DateTime.compare(at, latest) == :gt -> {:ok, latest}
          true -> {:ok, at}
        end

      {:error, _reason} ->
        {:ok, at}
    end
  end

  defp source_snapshot_key(%Database{} = source) do
    if (source.snapshot_generation || 0) > 0 do
      {:ok, Smolsqls.DataPlane.IdleSnapshots.object_key(source)}
    else
      case Smolsqls.Backups.list(source) do
        [latest | _] -> {:ok, latest.object_key}
        [] -> {:error, :no_snapshot}
      end
    end
  end

  defp parse_timestamp(%DateTime{} = at), do: {:ok, at}

  defp parse_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, at, _offset} -> {:ok, at}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp parse_timestamp(_), do: {:error, :invalid_timestamp}

  defp check_window(%DateTime{} = at) do
    now = DateTime.utc_now()
    earliest = DateTime.add(now, -@pitr_window_days * 24 * 3600, :second)

    if DateTime.compare(at, earliest) != :lt and DateTime.compare(at, now) != :gt do
      :ok
    else
      {:error, :timestamp_out_of_window}
    end
  end

  defp stamp_branch_point(attrs, {:pitr, at}), do: Map.put(attrs, "branch_point_at", at)
  defp stamp_branch_point(attrs, {:snapshot, _key}), do: attrs

  defp seed_and_place(%Database{} = source, %Database{} = child, seed) do
    with :ok <- do_seed(source, child, seed),
         {:ok, placed} <- DataPlane.place_branch(child) do
      {:ok, placed}
    else
      error ->
        cleanup_failed_branch(child)
        error
    end
  end

  defp cleanup_failed_branch(%Database{} = child) do
    case DataPlane.remove_database(child) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("branch cleanup for #{child.id} did not fully complete: #{inspect(other)}")
        :ok
    end
  end

  defp do_seed(_source, %Database{} = child, {:snapshot, source_key}) do
    DataPlane.seed_branch_from_object(child, source_key)
  end

  defp do_seed(%Database{} = source, %Database{} = child, {:pitr, at}) do
    DataPlane.seed_branch_from_pitr(source, child, at)
  end

  @doc """
  Removes a database. Blocked with `{:error, :has_branches}` when other
  databases were branched from it — the branches must be deleted first (no
  cascade). A self-FK on `source_database_id` backstops this at the database
  level.
  """
  @spec remove_database(Database.t()) :: {:ok, Database.t()} | {:error, term()}
  def remove_database(%Database{} = database) do
    if ControlPlane.has_branches?(database) do
      {:error, :has_branches}
    else
      with {:ok, database} <- ControlPlane.mark_deleting(database),
           :ok <- Infra.deprovision(database),
           :ok <- Smolsqls.Backups.delete_all(database) do
        DataPlane.remove_database(database)
      end
    end
  end

  @spec delete_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, term()}
  def delete_tenant(%Tenant{} = tenant) do
    case remove_tenant_databases(tenant) do
      :ok -> ControlPlane.delete_tenant(tenant)
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_tenant_databases(%Tenant{} = tenant) do
    case ControlPlane.list_databases(tenant) do
      [] -> :ok
      databases -> remove_leaves(tenant, databases)
    end
  end

  defp remove_leaves(%Tenant{} = tenant, databases) do
    case Enum.reject(databases, &ControlPlane.has_branches?/1) do
      [] ->
        {:error, :branch_cycle}

      leaves ->
        case remove_each(leaves) do
          :ok -> remove_tenant_databases(tenant)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp remove_each(databases) do
    Enum.reduce_while(databases, :ok, fn database, :ok ->
      case remove_database(database) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {database.id, reason}}}
      end
    end)
  end
end
