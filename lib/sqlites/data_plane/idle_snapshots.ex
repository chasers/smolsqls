defmodule Sqlites.DataPlane.IdleSnapshots do
  @moduledoc """
  Idle-stop snapshot shipping: when a database server idles out, a
  consistent `VACUUM INTO` snapshot is uploaded to
  `idle-snapshots/<tenant>/<db>/latest.db` and the metadb's
  `snapshot_generation` is bumped. Every session ships — skipping the
  upload for read-only sessions waits on a proper SQL parser. The
  volume then holds only a cache — activation on any node can rebuild
  the file from the object store.

  A `<file>.generation` sidecar records which shipped generation the
  local file is known to match; activation compares it against the
  metadb's generation to decide whether a cached file is current. A
  missing sidecar reads as generation 0, which matches never-shipped
  databases, so pre-existing volumes stay valid.
  """

  alias Sqlites.ControlPlane
  alias Sqlites.ControlPlane.Database

  @spec object_key(Database.t()) :: String.t()
  def object_key(%Database{} = database) do
    "idle-snapshots/#{database.tenant_id}/#{database.id}/latest.db"
  end

  @doc """
  Uploads the snapshot at `snapshot_path`, bumps the metadb generation,
  and stamps the local sidecar so the cached file counts as current.
  """
  @spec ship(Database.t(), Path.t()) :: {:ok, Database.t()} | {:error, term()}
  def ship(%Database{} = database, snapshot_path) do
    with {:ok, _size} <- Sqlites.ObjectStore.put_file(object_key(database), snapshot_path),
         {:ok, updated} <- ControlPlane.record_idle_snapshot(database) do
      if is_binary(database.file_path) do
        write_local_generation(database.file_path, updated.snapshot_generation)
      end

      {:ok, updated}
    end
  end

  @spec restore(Database.t(), Path.t()) :: :ok | {:error, term()}
  def restore(%Database{snapshot_generation: generation}, _dest_path)
      when generation in [nil, 0] do
    {:error, :no_idle_snapshot}
  end

  def restore(%Database{} = database, dest_path) do
    File.mkdir_p!(Path.dirname(dest_path))

    with :ok <- Sqlites.ObjectStore.fetch_to_file(object_key(database), dest_path) do
      write_local_generation(dest_path, database.snapshot_generation)
    end
  end

  @spec delete(Database.t()) :: :ok | {:error, term()}
  def delete(%Database{} = database) do
    Sqlites.ObjectStore.delete(object_key(database))
  end

  @spec local_generation(Path.t()) :: non_neg_integer()
  def local_generation(file_path) do
    with {:ok, contents} <- File.read(marker_path(file_path)),
         {generation, ""} <- Integer.parse(String.trim(contents)) do
      generation
    else
      _ -> 0
    end
  end

  @spec write_local_generation(Path.t(), non_neg_integer()) :: :ok
  def write_local_generation(file_path, generation) do
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(marker_path(file_path), Integer.to_string(generation))
  end

  @spec touch_marker(Path.t()) :: :ok
  def touch_marker(file_path) do
    path = marker_path(file_path)
    if File.exists?(path), do: File.touch!(path)
    :ok
  end

  @spec marker_path(Path.t()) :: Path.t()
  def marker_path(file_path), do: file_path <> ".generation"
end
