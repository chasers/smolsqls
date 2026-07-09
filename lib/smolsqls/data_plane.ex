defmodule Smolsqls.DataPlane do
  @moduledoc """
  Public API for the data plane: placing a database's server on this
  node, tearing it down, and executing queries routed to whichever node
  owns the file.
  """

  require Logger

  alias Smolsqls.ControlPlane
  alias Smolsqls.ControlPlane.Database
  alias Smolsqls.DataPlane.{IdleSnapshots, Litestream, Placement, Registry, Router, Supervisor}

  @gen_rpc_timeout :timer.seconds(15)

  @spec place_database(Database.t()) :: {:ok, Database.t()} | {:error, term()}
  def place_database(%Database{} = database) do
    node = Placement.pick_node()

    if node == Node.self() do
      place_database_locally(database)
    else
      place_database_on(node, database)
    end
  end

  @doc """
  Executed on the node chosen by placement — locally or via `gen_rpc`.
  """
  @spec place_database_locally(Database.t()) :: {:ok, Database.t()} | {:error, term()}
  def place_database_locally(%Database{} = database) do
    file_path = file_path_for(database)
    server_database = %{database | file_path: file_path}

    with {:ok, _pid} <-
           Supervisor.start_database(database.id, file_path, database: server_database) do
      ControlPlane.mark_placed(database, Node.self(), file_path)
    end
  end

  defp place_database_on(node, database) do
    case :gen_rpc.call(node, __MODULE__, :place_database_locally, [database], @gen_rpc_timeout) do
      {:badrpc, reason} -> {:error, {:badrpc, reason}}
      {:badtcp, reason} -> {:error, {:badtcp, reason}}
      result -> result
    end
  end

  @doc """
  Server-side copies a source artifact into a freshly created branch's
  idle-snapshot key, from which `place_branch/1` restores it. The object
  store is shared, so this runs on whatever node orchestrates the branch
  and never touches the parent's writer.
  """
  @spec seed_branch_from_object(Database.t(), String.t()) :: :ok | {:error, term()}
  def seed_branch_from_object(%Database{} = branch, source_object_key) do
    case Smolsqls.ObjectStore.copy(source_object_key, IdleSnapshots.object_key(branch)) do
      {:ok, _size} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The source replica's available point-in-time range (`%{earliest:, latest:}`).
  Reads the object store only, so it runs on whatever node orchestrates the
  branch. Used to clamp a requested point-in-time to what the replica holds.
  """
  @spec replica_range(Database.t()) ::
          {:ok, %{earliest: DateTime.t(), latest: DateTime.t()}} | {:error, term()}
  def replica_range(%Database{} = database), do: Litestream.replica_range(database)

  @doc """
  Seeds a branch from a point in time: restores the source's litestream
  replica to `timestamp` into a temp file, then uploads it to the branch's
  idle-snapshot key, from which `place_branch/1` restores it. Reads from the
  object store only — no impact on the source's writer.
  """
  @spec seed_branch_from_pitr(Database.t(), Database.t(), DateTime.t()) :: :ok | {:error, term()}
  def seed_branch_from_pitr(%Database{} = source, %Database{} = branch, %DateTime{} = timestamp) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "smolsqls-branch-#{branch.id}-#{System.unique_integer([:positive])}.db"
      )

    try do
      with :ok <- Litestream.restore(source, tmp, timestamp: timestamp),
           {:ok, _size} <- Smolsqls.ObjectStore.put_file(IdleSnapshots.object_key(branch), tmp) do
        :ok
      end
    after
      File.rm(tmp)
    end
  end

  @doc """
  Places a branch whose bytes already sit at its idle-snapshot key: picks a
  node, restores the seeded artifact into the child's file (the activation
  restore path), starts its server, and marks it placed. Like
  `place_database/1` but the child is restored from its seed rather than
  started on an empty file.
  """
  @spec place_branch(Database.t()) :: {:ok, Database.t()} | {:error, term()}
  def place_branch(%Database{} = database) do
    node = Placement.pick_node()

    if node == Node.self() do
      place_branch_locally(database)
    else
      case :gen_rpc.call(node, __MODULE__, :place_branch_locally, [database], @gen_rpc_timeout) do
        {:badrpc, reason} -> {:error, {:badrpc, reason}}
        {:badtcp, reason} -> {:error, {:badtcp, reason}}
        result -> result
      end
    end
  end

  @spec place_branch_locally(Database.t()) :: {:ok, Database.t()} | {:error, term()}
  def place_branch_locally(%Database{} = database) do
    file_path = file_path_for(database)
    server_database = %{database | file_path: file_path}

    with :ok <- ensure_local_file(server_database),
         {:ok, _pid} <-
           Supervisor.start_database(database.id, file_path, database: server_database) do
      ControlPlane.mark_placed(database, Node.self(), file_path)
    end
  end

  @spec remove_database(Database.t()) :: {:ok, Database.t()} | {:error, term()}
  def remove_database(%Database{} = database) do
    on_owner_node(database, :remove_database_locally, [database])
  end

  defp on_owner_node(%Database{} = database, function, args) do
    owner =
      case database.node do
        nil -> Node.self()
        node_name -> String.to_existing_atom(node_name)
      end

    if owner == Node.self() do
      apply(__MODULE__, function, args)
    else
      case :gen_rpc.call(owner, __MODULE__, function, args, @gen_rpc_timeout) do
        {:badrpc, reason} -> {:error, {:badrpc, reason}}
        {:badtcp, reason} -> {:error, {:badtcp, reason}}
        result -> result
      end
    end
  end

  @doc """
  Starts the database's server on its owning node if it isn't running —
  the activate-on-miss path for lazily woken databases.
  """
  @spec activate_database(Database.t()) :: {:ok, pid()} | {:error, term()}
  def activate_database(%Database{status: :active, file_path: file_path} = database)
      when is_binary(file_path) do
    on_owner_node(database, :activate_database_locally, [database])
  end

  def activate_database(%Database{}), do: {:error, :database_not_active}

  @doc """
  Starts the server for a database this node owns. Activation trusts
  placement plus the snapshot generation, never bare file presence: a
  local file whose generation sidecar is behind the metadb is a stale
  cache — discarded and re-fetched. Restore order is litestream
  replica (premium) → idle snapshot → latest manual backup → error.
  A database is never started from an empty file.
  """
  @spec activate_database_locally(Database.t()) :: {:ok, pid()} | {:error, term()}
  def activate_database_locally(%Database{} = database) do
    with :ok <- ensure_local_file(database) do
      Supervisor.start_database(database.id, database.file_path, database: database)
    end
  end

  defp ensure_local_file(%Database{} = database) do
    if local_file_current?(database) do
      Smolsqls.Telemetry.activation("cache_hit")
      :ok
    else
      discard_stale_local_file(database)
      started = System.monotonic_time(:millisecond)

      case restore_for_activation(database) do
        {:ok, path} ->
          Smolsqls.Telemetry.activation(path, System.monotonic_time(:millisecond) - started)
          :ok

        {:error, reason} ->
          Smolsqls.Telemetry.activation("missing")
          {:error, reason}
      end
    end
  end

  defp local_file_current?(%Database{file_path: file_path} = database) do
    File.exists?(file_path) and
      IdleSnapshots.local_generation(file_path) >= (database.snapshot_generation || 0)
  end

  defp discard_stale_local_file(%Database{file_path: file_path} = database) do
    if File.exists?(file_path) do
      Logger.info(
        "discarding stale local file for #{database.id}: local generation " <>
          "#{IdleSnapshots.local_generation(file_path)} < #{database.snapshot_generation}"
      )

      delete_local_files(file_path)
    end

    :ok
  end

  defp restore_for_activation(%Database{file_path: file_path} = database) do
    cond do
      database.litestream_enabled and match?(:ok, Litestream.restore(database, file_path)) ->
        IdleSnapshots.write_local_generation(file_path, database.snapshot_generation || 0)
        {:ok, "litestream"}

      match?(:ok, IdleSnapshots.restore(database, file_path)) ->
        {:ok, "idle_snapshot"}

      match?(:ok, restore_latest_backup(database)) ->
        IdleSnapshots.write_local_generation(file_path, database.snapshot_generation || 0)
        {:ok, "backup"}

      true ->
        {:error, :database_file_missing}
    end
  end

  defp restore_latest_backup(%Database{file_path: file_path} = database) do
    case Smolsqls.Backups.list(database) do
      [latest | _] -> Smolsqls.ObjectStore.fetch_to_file(latest.object_key, file_path)
      [] -> {:error, :no_backups}
    end
  end

  @doc """
  Stops a database's server through the idle-stop path — the snapshot
  ships first when the session was dirty (or the database has never
  shipped). Used by drains to hand off hot databases before their
  placement rows move.
  """
  @spec idle_stop_database(Database.t()) :: :ok | {:error, term()}
  def idle_stop_database(%Database{} = database) do
    on_owner_node(database, :idle_stop_database_locally, [database])
  end

  @spec idle_stop_database_locally(Database.t()) :: :ok
  def idle_stop_database_locally(%Database{} = database) do
    Smolsqls.DataPlane.Database.Server.idle_stop(database.id)
  end

  @doc """
  Pushes freshly resolved limits to a running server on its owning
  node. No-op when the server is cold — activation resolves limits
  itself. For internal tooling after editing a `limits` row:

      bin/smolsqls rpc 'Smolsqls.ControlPlane.get_database("...") |> Smolsqls.DataPlane.push_limits()'
  """
  @spec push_limits(Database.t()) :: :ok | {:error, term()}
  def push_limits(%Database{} = database) do
    on_owner_node(database, :push_limits_locally, [database])
  end

  @spec push_limits_locally(Database.t()) :: :ok | {:error, term()}
  def push_limits_locally(%Database{} = database) do
    case Registry.whereis(database.id) do
      pid when is_pid(pid) ->
        Smolsqls.DataPlane.Database.Server.set_limits(pid, Smolsqls.Limits.resolve(database))

      :undefined ->
        :ok
    end
  end

  @doc """
  Applies a live replication toggle to a running server: registers or
  stops litestream on the owning node. No-op when the server is cold —
  activation applies the flag.
  """
  @spec set_replication(Database.t()) :: :ok
  def set_replication(%Database{} = database) do
    on_owner_node(database, :set_replication_locally, [database])
  end

  @spec set_replication_locally(Database.t()) :: :ok
  def set_replication_locally(%Database{} = database) do
    case Registry.whereis(database.id) do
      pid when is_pid(pid) ->
        if database.litestream_enabled do
          Litestream.register(database)
        else
          Litestream.stop(database.file_path)
        end

        :ok

      :undefined ->
        :ok
    end
  end

  @doc """
  Takes a consistent snapshot on the owning node (`VACUUM INTO` through
  the single writer) and uploads it to the object store. Returns the
  object key and size for the control plane to record.
  """
  @spec backup_database(Database.t(), String.t()) ::
          {:ok, %{object_key: String.t(), size_bytes: non_neg_integer()}} | {:error, term()}
  def backup_database(%Database{} = database, object_key) do
    on_owner_node(database, :backup_database_locally, [database, object_key])
  end

  @spec backup_database_locally(Database.t(), String.t()) ::
          {:ok, %{object_key: String.t(), size_bytes: non_neg_integer()}} | {:error, term()}
  def backup_database_locally(%Database{} = database, object_key) do
    snapshot_path =
      Path.join(
        System.tmp_dir!(),
        "smolsqls-backup-#{database.id}-#{System.unique_integer([:positive])}.db"
      )

    try do
      with {:ok, _} <- Router.snapshot_into(database.id, snapshot_path),
           {:ok, size_bytes} <- Smolsqls.ObjectStore.put_file(object_key, snapshot_path) do
        {:ok, %{object_key: object_key, size_bytes: size_bytes}}
      end
    after
      File.rm(snapshot_path)
    end
  end

  @doc """
  Fetches a backup artifact from the object store onto the owning node
  and swaps it in through the drain/swap/restart path.
  """
  @spec restore_database(Database.t(), String.t()) :: :ok | {:error, term()}
  def restore_database(%Database{} = database, object_key) do
    on_owner_node(database, :restore_database_locally, [database, object_key])
  end

  @spec restore_database_locally(Database.t(), String.t()) :: :ok | {:error, term()}
  def restore_database_locally(%Database{} = database, object_key) do
    fetch_path =
      Path.join(
        System.tmp_dir!(),
        "smolsqls-restore-#{database.id}-#{System.unique_integer([:positive])}.db"
      )

    try do
      with :ok <- Smolsqls.ObjectStore.fetch_to_file(object_key, fetch_path) do
        restore_from_file_locally(database, fetch_path)
      end
    after
      File.rm(fetch_path)
    end
  end

  @spec restore_from_file(Database.t(), Path.t()) :: :ok | {:error, term()}
  def restore_from_file(%Database{} = database, backup_path) do
    on_owner_node(database, :restore_from_file_locally, [database, backup_path])
  end

  @doc """
  Executed on the node that owns the database file — locally or via
  `gen_rpc`. Drains the writer, swaps in the backup, and restarts it.
  """
  @spec restore_from_file_locally(Database.t(), Path.t()) :: :ok | {:error, term()}
  def restore_from_file_locally(%Database{} = database, backup_path) do
    if File.exists?(backup_path) and is_binary(database.file_path) do
      :ok = Supervisor.stop_database(database.id)
      Litestream.stop(database.file_path)
      install_local_file(database.file_path, backup_path)

      case Supervisor.start_database(database.id, database.file_path, database: database) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :backup_not_found}
    end
  end

  @doc """
  Installs a materialized SQLite file at `file_path`: drops any stale
  WAL/SHM companions and copies `source_path` into place. The shared
  byte-install step for both restoring a database onto its own file and
  seeding a fresh (branched/cloned) file from a source. Does not touch
  any running server — callers stop/start around it as their mode
  requires.
  """
  @spec install_local_file(Path.t(), Path.t()) :: :ok
  def install_local_file(file_path, source_path) do
    File.mkdir_p!(Path.dirname(file_path))
    File.rm(file_path <> "-wal")
    File.rm(file_path <> "-shm")
    File.cp!(source_path, file_path)
    :ok
  end

  @doc """
  Executed on the node that owns the database file — locally or via
  `gen_rpc`.
  """
  @spec remove_database_locally(Database.t()) :: {:ok, Database.t()} | {:error, term()}
  def remove_database_locally(%Database{} = database) do
    :ok = Supervisor.stop_database(database.id)

    if database.file_path do
      Litestream.stop(database.file_path)
      delete_local_files(database.file_path)
    end

    IdleSnapshots.delete(database)
    ControlPlane.delete_database(database)
  end

  @doc """
  Removes a database's cached files from the local volume: the file,
  its WAL/SHM companions, and the generation sidecar.
  """
  @spec delete_local_files(Path.t()) :: :ok
  def delete_local_files(file_path) do
    File.rm(file_path)
    File.rm(file_path <> "-wal")
    File.rm(file_path <> "-shm")
    File.rm(IdleSnapshots.marker_path(file_path))
    :ok
  end

  @spec query(String.t(), String.t(), [term()] | map(), timeout(), pid() | nil) ::
          {:ok, Smolsqls.DataPlane.Database.Server.query_result()} | {:error, term()}
  def query(database_id, sql, args \\ [], timeout \\ :timer.seconds(30), owner \\ nil) do
    Router.query(database_id, sql, args, timeout, owner)
  end

  @spec describe(String.t(), String.t(), timeout(), pid() | nil) ::
          {:ok, Smolsqls.DataPlane.Database.Server.describe_result()} | {:error, term()}
  def describe(database_id, sql, timeout \\ :timer.seconds(30), owner \\ nil) do
    Router.describe(database_id, sql, timeout, owner)
  end

  @spec sequence(String.t(), String.t(), timeout(), pid() | nil) :: :ok | {:error, term()}
  def sequence(database_id, sql, timeout \\ :timer.seconds(30), owner \\ nil) do
    Router.sequence(database_id, sql, timeout, owner)
  end

  @spec autocommit?(String.t(), pid() | nil) :: boolean()
  def autocommit?(database_id, owner) do
    Router.autocommit?(database_id, owner)
  end

  @spec owner_node(String.t()) :: {:ok, node()} | {:error, :not_found}
  def owner_node(database_id), do: Registry.owner_node(database_id)

  @doc """
  Whether a database currently has a running server anywhere in the
  cluster (resolved through the cluster-wide `:syn` registry).
  """
  @spec database_hot?(String.t()) :: boolean()
  def database_hot?(database_id), do: Registry.whereis(database_id) != :undefined

  defp file_path_for(%Database{} = database) do
    data_dir()
    |> Path.join(database.tenant_id)
    |> Path.join(database.id <> ".db")
  end

  defp data_dir do
    Application.fetch_env!(:smolsqls, :data_dir)
  end
end
