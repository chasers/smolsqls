defmodule SqlitesOperator.Controller.SqliteNodeController do
  @moduledoc """
  Reconciles SqliteNode resources — one per data-plane node.

  Per reconcile it refreshes observed node state onto `status`:
  replication-slot health straight from `pg_replication_slots` on the
  metadb (surfacing `wal_status`/retained WAL before a lagging replica
  becomes an incident) and the node's database count from the
  control-plane `databases` table.

  Drain (`spec.drain: true`) inserts a request row into the metadb's
  `node_drains` table — the data plane's drain worker claims it,
  idle-stops hot databases so their snapshots ship, and reassigns
  placement rows; this controller only reports the request's progress
  on `status.drain`. Re-draining a node requires deleting its
  `node_drains` row. On delete, the node's replication slot is dropped
  so a decommissioned node can never bloat WAL retention.
  """

  use Bonny.ControllerV2

  require Logger

  step(Bonny.Pluggable.SkipObservedGenerations)
  step(:handle_event)

  @impl true
  def rbac_rules do
    []
  end

  def handle_event(%Bonny.Axn{action: action} = axn, _opts)
      when action in [:add, :modify, :reconcile] do
    axn
    |> ensure_drain_requested()
    |> refresh_status()
    |> success_event()
  end

  def handle_event(%Bonny.Axn{action: :delete} = axn, _opts) do
    slot = slot_name(axn.resource)

    case drop_replication_slot(slot) do
      :ok -> Logger.info("dropped replication slot #{slot}")
      {:error, reason} -> Logger.error("failed to drop slot #{slot}: #{inspect(reason)}")
    end

    axn
  end

  defp refresh_status(axn) do
    slot = slot_name(axn.resource)
    erlang_node = get_in(axn.resource, ["spec", "erlangNode"])

    update_status(axn, fn status ->
      status
      |> Map.put("replicationSlot", slot_status(slot))
      |> Map.put("databaseCount", database_count(erlang_node))
      |> Map.put("drain", drain_status(erlang_node))
    end)
  end

  defp ensure_drain_requested(axn) do
    erlang_node = get_in(axn.resource, ["spec", "erlangNode"])

    if get_in(axn.resource, ["spec", "drain"]) == true and is_binary(erlang_node) do
      query = """
      INSERT INTO node_drains (node, requested_at)
      VALUES ($1, now()) ON CONFLICT (node) DO NOTHING
      """

      case metadb_query(query, [erlang_node]) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("drain request insert failed: #{inspect(reason)}")
      end
    end

    axn
  end

  defp drain_status(nil), do: nil

  defp drain_status(erlang_node) do
    query = """
    SELECT requested_at, started_at, started_by, completed_at, reassigned, error
    FROM node_drains WHERE node = $1
    """

    case metadb_query(query, [erlang_node]) do
      {:ok, %{rows: [[requested_at, started_at, started_by, completed_at, reassigned, error]]}} ->
        %{
          "phase" => drain_phase(started_at, completed_at, error),
          "requestedAt" => timestamp(requested_at),
          "startedAt" => timestamp(started_at),
          "startedBy" => started_by,
          "completedAt" => timestamp(completed_at),
          "reassigned" => reassigned,
          "error" => error
        }

      {:ok, %{rows: []}} ->
        nil

      {:error, reason} ->
        Logger.error("drain status query failed: #{inspect(reason)}")
        nil
    end
  end

  defp drain_phase(_started_at, completed_at, error) when not is_nil(completed_at) do
    if error, do: "Failed", else: "Completed"
  end

  defp drain_phase(started_at, _completed_at, _error) when not is_nil(started_at), do: "Running"
  defp drain_phase(_started_at, _completed_at, _error), do: "Requested"

  defp timestamp(nil), do: nil
  defp timestamp(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive) <> "Z"
  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp slot_status(slot) do
    query = """
    SELECT active, wal_status,
           pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint
    FROM pg_replication_slots WHERE slot_name = $1
    """

    case metadb_query(query, [slot]) do
      {:ok, %{rows: [[active, wal_status, retained]]}} ->
        %{
          "name" => slot,
          "active" => active,
          "walStatus" => wal_status,
          "retainedBytes" => retained || 0
        }

      {:ok, %{rows: []}} ->
        %{"name" => slot, "active" => false, "walStatus" => "absent", "retainedBytes" => 0}

      {:error, reason} ->
        Logger.error("slot status query failed: #{inspect(reason)}")
        nil
    end
  end

  defp database_count(nil), do: 0

  defp database_count(erlang_node) do
    case metadb_query("SELECT count(*) FROM databases WHERE node = $1", [erlang_node]) do
      {:ok, %{rows: [[count]]}} -> count
      {:error, _} -> 0
    end
  end

  defp drop_replication_slot(slot) do
    query = """
    SELECT pg_drop_replication_slot(slot_name)
    FROM pg_replication_slots WHERE slot_name = $1 AND NOT active
    """

    case metadb_query(query, [slot]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp slot_name(resource) do
    case get_in(resource, ["spec", "erlangNode"]) do
      nil ->
        "sqlites_unknown"

      erlang_node ->
        sanitized =
          erlang_node
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9_]/, "_")

        String.slice("sqlites_" <> sanitized, 0, 63)
    end
  end

  defp metadb_query(sql, params) do
    with {:ok, conn} <- metadb_conn() do
      case Postgrex.query(conn, sql, params) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp metadb_conn do
    case :persistent_term.get({__MODULE__, :metadb}, nil) do
      nil ->
        with {:ok, conn} <- Postgrex.start_link(metadb_config()) do
          :persistent_term.put({__MODULE__, :metadb}, conn)
          {:ok, conn}
        end

      conn ->
        {:ok, conn}
    end
  end

  defp metadb_config do
    Application.fetch_env!(:sqlites_operator, :metadb)
  end
end
