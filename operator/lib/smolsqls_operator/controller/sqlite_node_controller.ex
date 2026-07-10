defmodule SmolsqlsOperator.Controller.SqliteNodeController do
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

  Automatic failover: when two independent signals agree that a node
  is gone — its pod not Ready for longer than the configured window
  AND its replication slot inactive on the metadb — an `evacuate`
  request is inserted on the same bus. The data plane worker re-checks
  liveness at claim time, so a reconnected node cancels the request.
  A completed evacuation row is cleared only once the pod is Ready
  again, which is the flap-damping cooldown: at most one automatic
  evacuation per node per outage.
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
    slot_status = slot_status(slot)
    pod_ready = pod_ready?(axn)
    not_ready_since = track_not_ready(axn, pod_ready)

    handle_auto_failover(erlang_node, pod_ready, not_ready_since, slot_status)

    update_status(axn, fn status ->
      status
      |> Map.put("replicationSlot", slot_status)
      |> Map.put("region", node_region(erlang_node))
      |> Map.put("databaseCount", database_count(erlang_node))
      |> Map.put("drain", drain_status(erlang_node))
      |> Map.put("podReady", pod_ready)
      |> Map.put("notReadySince", not_ready_since)
    end)
  end

  defp pod_ready?(axn) do
    namespace = get_in(axn.resource, ["metadata", "namespace"]) || "smolsqls"
    ordinal = get_in(axn.resource, ["spec", "ordinal"])

    with true <- is_integer(ordinal),
         {:ok, pod} <-
           K8s.Client.get("v1", "Pod", namespace: namespace, name: "smolsqls-#{ordinal}")
           |> K8s.Client.put_conn(axn.conn)
           |> K8s.Client.run() do
      pod
      |> get_in(["status", "conditions"])
      |> List.wrap()
      |> Enum.any?(fn condition ->
        condition["type"] == "Ready" and condition["status"] == "True"
      end)
    else
      _ -> false
    end
  end

  defp track_not_ready(_axn, true), do: nil

  defp track_not_ready(axn, false) do
    get_in(axn.resource, ["status", "notReadySince"]) ||
      DateTime.to_iso8601(DateTime.utc_now())
  end

  defp handle_auto_failover(nil, _pod_ready, _not_ready_since, _slot_status), do: :ok

  defp handle_auto_failover(erlang_node, true, _not_ready_since, _slot_status) do
    clear_completed_evacuation(erlang_node)
  end

  defp handle_auto_failover(erlang_node, false, not_ready_since, slot_status) do
    config = auto_evacuate_config()

    if config.enabled and slot_inactive?(slot_status) and
         down_longer_than?(not_ready_since, config.window_seconds) do
      request_evacuation(erlang_node)
    end

    :ok
  end

  defp slot_inactive?(%{"active" => false}), do: true
  defp slot_inactive?(_slot_status), do: false

  defp down_longer_than?(nil, _window), do: false

  defp down_longer_than?(not_ready_since, window_seconds) do
    case DateTime.from_iso8601(not_ready_since) do
      {:ok, since, _offset} ->
        DateTime.diff(DateTime.utc_now(), since, :second) >= window_seconds

      _ ->
        false
    end
  end

  defp request_evacuation(erlang_node) do
    query = """
    INSERT INTO node_drains (node, kind, requested_at)
    VALUES ($1, 'evacuate', now()) ON CONFLICT (node) DO NOTHING
    """

    case metadb_query(query, [erlang_node]) do
      {:ok, %{num_rows: 1}} -> Logger.warning("auto-evacuation requested for #{erlang_node}")
      {:ok, _} -> :ok
      {:error, reason} -> Logger.error("evacuation request insert failed: #{inspect(reason)}")
    end
  end

  defp clear_completed_evacuation(erlang_node) do
    query = """
    DELETE FROM node_drains
    WHERE node = $1 AND kind = 'evacuate' AND completed_at IS NOT NULL
    """

    case metadb_query(query, [erlang_node]) do
      {:ok, %{num_rows: n}} when n > 0 ->
        Logger.info("cleared completed evacuation for recovered node #{erlang_node}")

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("evacuation cleanup failed: #{inspect(reason)}")
    end
  end

  defp auto_evacuate_config do
    config = Application.get_env(:smolsqls_operator, :auto_evacuate, [])

    %{
      enabled: Keyword.get(config, :enabled, true),
      window_seconds: Keyword.get(config, :window_seconds, 120)
    }
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

  defp node_region(nil), do: nil

  defp node_region(erlang_node) do
    case metadb_query("SELECT region FROM nodes WHERE node_name = $1", [erlang_node]) do
      {:ok, %{rows: [[region]]}} -> region
      _ -> nil
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
        "smolsqls_unknown"

      erlang_node ->
        sanitized =
          erlang_node
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9_]/, "_")

        String.slice("smolsqls_" <> sanitized, 0, 63)
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
    Application.fetch_env!(:smolsqls_operator, :metadb)
  end
end
