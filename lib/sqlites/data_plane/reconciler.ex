defmodule Sqlites.DataPlane.Reconciler do
  @moduledoc """
  Boot-time placement reconciliation: the volume is the source of truth
  for which databases this node owns, not the node name recorded in the
  control plane. On startup, walk the data directory and claim any
  database whose file lives here but whose record points elsewhere —
  covering node renames, volumes remounted into a different slot, and
  failover restores. Does not start servers; activation stays lazy.
  """

  use Task, restart: :transient

  import Ecto.Query

  require Logger

  alias Sqlites.ControlPlane.Database
  alias Sqlites.Repo

  @claim_chunk_size 1000

  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  def run do
    if Application.get_env(:sqlites, :reconcile_on_boot, true) do
      reconcile()
    end
  end

  @spec reconcile() :: %{found: non_neg_integer(), claimed: non_neg_integer()}
  def reconcile do
    node_name = to_string(Node.self())
    data_dir = Application.fetch_env!(:sqlites, :data_dir)
    local_ids = discover_local_database_ids(data_dir)

    claimed =
      local_ids
      |> Enum.chunk_every(@claim_chunk_size)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} =
          Database
          |> where([d], d.id in ^chunk)
          |> where([d], d.node != ^node_name or is_nil(d.node))
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
    end

    %{found: length(local_ids), claimed: claimed}
  end

  defp discover_local_database_ids(data_dir) do
    [data_dir, "*", "*.db"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".db"))
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
  end
end
