defmodule Sqlites.DataPlane.Reconciler do
  @moduledoc """
  Boot-time placement reconciliation: the volume is the source of truth
  for which databases this node owns, not the node name recorded in the
  control plane. On startup, walk the data directory and claim any
  database whose file lives here but whose record points elsewhere —
  covering node renames and volumes remounted into a different slot.
  Databases whose record points at a currently-connected node are never
  reclaimed: a returning node's local files are stale copies when its
  databases were failed over to survivors while it was down. Does not
  start servers; activation stays lazy.

  Two guards close the returning-node races (found in the phase 5 kind
  verification):

    * Reconciliation waits for cluster membership to settle (first
      libcluster connect, bounded by `:reconciler_membership_timeout`)
      — a reconcile racing ahead of the cluster join sees an empty
      `Node.list()` and would treat every live owner as dead.
    * A node with a completed `drain`/`evacuate` row on the
      `node_drains` bus skips reclaim entirely: its placement rows
      were deliberately moved off it, and its local files are stale by
      design. The operator clears the row once the node is Ready
      again, so the *next* boot reconciles normally.
  """

  use Task, restart: :transient

  import Ecto.Query

  require Logger

  alias Sqlites.ControlPlane.Database
  alias Sqlites.Repo

  @claim_chunk_size 1000
  @membership_poll_ms 250

  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  def run do
    if Application.get_env(:sqlites, :reconcile_on_boot, true) do
      await_cluster_membership()
      reconcile()
    end
  end

  @spec reconcile() :: %{found: non_neg_integer(), claimed: non_neg_integer()}
  def reconcile do
    node_name = to_string(Node.self())

    if evacuated?(node_name) do
      Logger.warning(
        "reconciler: #{node_name} has a completed drain/evacuation on the bus; " <>
          "skipping reclaim — local files are stale by design"
      )

      %{found: 0, claimed: 0}
    else
      claim_local_files(node_name)
    end
  end

  defp claim_local_files(node_name) do
    data_dir = Application.fetch_env!(:sqlites, :data_dir)
    local_ids = discover_local_database_ids(data_dir)

    live_other_nodes = Enum.map(Node.list(), &to_string/1)

    claimed =
      local_ids
      |> Enum.chunk_every(@claim_chunk_size)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} =
          Database
          |> where([d], d.id in ^chunk)
          |> where([d], d.node != ^node_name or is_nil(d.node))
          |> where([d], is_nil(d.node) or d.node not in ^live_other_nodes)
          |> update([d],
            set: [
              node: ^node_name,
              file_path:
                fragment(
                  "? || '/' || ?::text || '/' || ?::text || '.db'",
                  ^data_dir,
                  d.tenant_id,
                  d.id
                ),
              updated_at: ^DateTime.utc_now()
            ]
          )
          |> Repo.update_all([])

        acc + count
      end)

    if claimed > 0 do
      Logger.info("reconciler claimed #{claimed} database(s) for #{node_name}")
      :telemetry.execute([:sqlites, :reconciler, :claimed], %{count: claimed}, %{})
    end

    %{found: length(local_ids), claimed: claimed}
  end

  defp evacuated?(node_name) do
    Sqlites.Drain.Request
    |> where([r], r.node == ^node_name and not is_nil(r.completed_at) and is_nil(r.error))
    |> Repo.exists?()
  end

  defp await_cluster_membership do
    deadline =
      System.monotonic_time(:millisecond) +
        Application.get_env(:sqlites, :reconciler_membership_timeout, :timer.seconds(15))

    await_cluster_membership(deadline)
  end

  defp await_cluster_membership(deadline) do
    cond do
      Node.list() != [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.info("reconciler: no cluster peers appeared before the membership timeout")
        :ok

      true ->
        Process.sleep(@membership_poll_ms)
        await_cluster_membership(deadline)
    end
  end

  defp discover_local_database_ids(data_dir) do
    [data_dir, "*", "*.db"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".db"))
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
  end
end
