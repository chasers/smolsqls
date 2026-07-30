defmodule Smolsqls.DataPlane.Fence do
  @moduledoc """
  Fencing for returning nodes: a server running locally for a database
  whose placement row points elsewhere is serving a stale copy — its
  databases were evacuated to survivors while this node was down or
  partitioned. The sweep compares local servers against placement and
  stops mismatches WITHOUT shipping (our snapshot must never clobber
  the new owner's).

  A mismatch must be observed on two consecutive sweeps before the
  server is stopped, so read-model replication lag on fresh remote
  placements never fences a healthy server.
  """

  use GenServer

  require Logger

  alias Smolsqls.ControlPlane
  alias Smolsqls.ControlPlane.Database
  alias Smolsqls.DataPlane.Database.Server
  alias Smolsqls.DataPlane.Supervisor

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{flagged: MapSet.new()}}
  end

  @impl true
  def handle_info(:sweep, state) do
    flagged = sweep(state.flagged)
    schedule_sweep()
    {:noreply, %{state | flagged: flagged}}
  end

  @spec sweep(MapSet.t()) :: MapSet.t()
  def sweep(previously_flagged \\ MapSet.new()) do
    self_name = to_string(Node.self())

    mismatched =
      Supervisor.local_servers()
      |> Enum.flat_map(fn pid ->
        case Server.database_id(pid) do
          {:ok, database_id} -> [database_id]
          {:error, _} -> []
        end
      end)
      |> Enum.filter(&misplaced?(&1, self_name))
      |> MapSet.new()

    mismatched
    |> MapSet.intersection(previously_flagged)
    |> Enum.each(fn database_id ->
      Logger.warning(
        "fencing #{database_id}: placement moved off #{self_name}; stopping without ship"
      )

      Smolsqls.Telemetry.fenced()
      Supervisor.stop_database(database_id)
    end)

    mismatched
  end

  defp misplaced?(database_id, self_name) do
    case ControlPlane.lookup_database(database_id) do
      {:ok, %Database{node: node}} when is_binary(node) -> node != self_name
      _ -> false
    end
  end

  defp schedule_sweep do
    interval = Application.get_env(:smolsqls, __MODULE__, [])[:interval] || :timer.seconds(30)
    Process.send_after(self(), :sweep, interval)
  end
end
