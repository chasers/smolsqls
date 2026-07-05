defmodule Sqlites.DataPlane.CacheEvictor do
  @moduledoc """
  LRU sweep over the local volume, which idle-snapshot shipping demoted
  to a cache. When the total size of database files crosses the
  configured high-water mark, cold databases provably in the object
  store are deleted oldest-first until usage falls under the low-water
  mark.

  Eviction is safe only when the shipped snapshot covers every local
  byte: the database must be cold (no registered server), its metadb
  `snapshot_generation` positive, and neither the file nor its WAL
  written after the generation sidecar — the server touches the
  sidecar last on clean shutdown, so a crashed dirty session leaves
  newer mtimes and is never evicted.
  """

  use GenServer

  require Logger

  alias Sqlites.ControlPlane
  alias Sqlites.ControlPlane.Database
  alias Sqlites.DataPlane.IdleSnapshots
  alias Sqlites.DataPlane.Registry

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @spec sweep() :: %{evicted: non_neg_integer(), freed_bytes: non_neg_integer()}
  def sweep do
    high_water = config()[:high_water_bytes]
    entries = local_entries()
    total = entries |> Enum.map(& &1.size) |> Enum.sum()

    if is_integer(high_water) and total > high_water do
      target = trunc(high_water * low_water_ratio())
      evict(entries, total, target)
    else
      %{evicted: 0, freed_bytes: 0}
    end
  end

  defp evict(entries, total, target) do
    result =
      entries
      |> Enum.filter(&evictable?/1)
      |> Enum.sort_by(& &1.mtime)
      |> Enum.reduce_while(%{evicted: 0, freed_bytes: 0}, fn entry, acc ->
        if total - acc.freed_bytes <= target do
          {:halt, acc}
        else
          Sqlites.DataPlane.delete_local_files(entry.file_path)
          {:cont, %{evicted: acc.evicted + 1, freed_bytes: acc.freed_bytes + entry.size}}
        end
      end)

    if result.evicted > 0 do
      Logger.info(
        "cache evictor freed #{result.freed_bytes} bytes across #{result.evicted} database(s)"
      )
    end

    result
  end

  defp evictable?(entry) do
    with :undefined <- Registry.whereis(entry.database_id),
         %Database{snapshot_generation: generation} when generation > 0 <-
           ControlPlane.lookup_database(entry.database_id) do
      shipped_covers_local_file?(entry.file_path)
    else
      _ -> false
    end
  end

  defp shipped_covers_local_file?(file_path) do
    case mtime(IdleSnapshots.marker_path(file_path)) do
      nil ->
        false

      marker_mtime ->
        [file_path, file_path <> "-wal"]
        |> Enum.map(&mtime/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.all?(&(&1 <= marker_mtime))
    end
  end

  defp local_entries do
    data_dir = Application.fetch_env!(:sqlites, :data_dir)

    [data_dir, "*", "*.db"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(fn file_path ->
      database_id = Path.basename(file_path, ".db")

      case Ecto.UUID.cast(database_id) do
        {:ok, _} ->
          [
            %{
              database_id: database_id,
              file_path: file_path,
              size: files_size(file_path),
              mtime: mtime(file_path) || 0
            }
          ]

        :error ->
          []
      end
    end)
  end

  defp files_size(file_path) do
    [file_path, file_path <> "-wal", file_path <> "-shm"]
    |> Enum.map(fn path ->
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> size
        {:error, _} -> 0
      end
    end)
    |> Enum.sum()
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> nil
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, config()[:interval] || :timer.minutes(1))
  end

  defp low_water_ratio do
    config()[:low_water_ratio] || 0.8
  end

  defp config do
    Application.get_env(:sqlites, __MODULE__, [])
  end
end
