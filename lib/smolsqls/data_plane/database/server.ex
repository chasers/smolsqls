defmodule Smolsqls.DataPlane.Database.Server do
  @moduledoc """
  Owns the single connection to one SQLite database file and serializes
  all access to it. Exactly one of these runs per database across the
  whole cluster, registered in `:syn` under the `:smolsqls_databases`
  scope so any node can locate it.

  Every session is assumed dirty: idle-stop always ships a
  `VACUUM INTO` snapshot to the object store. Skipping the upload for
  read-only sessions is deliberately deferred until a proper SQL
  parser can classify statements — a misclassified write would lose
  data, so no heuristic gets to make that call. After a clean
  shutdown (successful ship) the generation sidecar is touched last,
  so the cache evictor can prove the local file has no writes newer
  than the shipped snapshot.

  Interactive transactions take a **writer lease**: when a statement
  from an identified owner (the Hrana WebSocket connection) leaves the
  connection in a transaction, that owner holds the lease and every
  other caller fails fast with `:database_busy_in_transaction`. The
  lease is exact — it follows `sqlite3_get_autocommit` via
  `Sqlite3.transaction_status/1`, not SQL parsing — and is bounded by
  the `txn_timeout_ms` limit (auto-ROLLBACK), the owner's death
  (monitored, auto-ROLLBACK), and server shutdown (ROLLBACK before the
  snapshot ships). A transaction left open by an ownerless caller is
  rolled back immediately, so the shared connection can never leak
  state.
  """

  use GenServer, restart: :transient

  require Logger

  alias Exqlite.Sqlite3
  alias Smolsqls.ControlPlane.Database
  alias Smolsqls.DataPlane.IdleSnapshots
  alias Smolsqls.DataPlane.Registry

  @type query_result :: %{
          columns: [String.t()],
          rows: [[term()]],
          num_changes: integer(),
          last_insert_rowid: integer()
        }

  def start_link(opts) do
    database_id = Keyword.fetch!(opts, :database_id)
    GenServer.start_link(__MODULE__, opts, name: Registry.via(database_id))
  end

  @default_query_timeout :timer.seconds(30)

  @denied_authorizer_actions [:attach, :detach]

  @type describe_result :: %{columns: [String.t()], param_count: non_neg_integer()}

  @spec query(pid() | String.t(), String.t(), [term()] | map(), timeout(), pid() | nil) ::
          {:ok, query_result()} | {:error, term()}
  def query(server, sql, args \\ [], timeout \\ @default_query_timeout, owner \\ nil) do
    call(server, {:query, sql, args, owner}, timeout)
  end

  @doc """
  Prepares without executing: column names and bound-parameter count,
  for Hrana `describe`.
  """
  @spec describe(pid() | String.t(), String.t(), timeout(), pid() | nil) ::
          {:ok, describe_result()} | {:error, term()}
  def describe(server, sql, timeout \\ @default_query_timeout, owner \\ nil) do
    call(server, {:describe, sql, owner}, timeout)
  end

  @doc """
  Executes a multi-statement SQL script (Hrana `sequence`); no results
  are returned. Always marks the session dirty.
  """
  @spec sequence(pid() | String.t(), String.t(), timeout(), pid() | nil) ::
          :ok | {:error, term()}
  def sequence(server, sql, timeout \\ @default_query_timeout, owner \\ nil) do
    call(server, {:sequence, sql, owner}, timeout)
  end

  @doc """
  Takes a consistent `VACUUM INTO` snapshot to `path`. This is a
  privileged control-plane operation (backups, idle ships) and is not
  subject to the tenant SQL authorizer that otherwise denies `ATTACH`
  (and therefore `VACUUM`) on tenant-submitted statements.
  """
  @spec snapshot_into(pid() | String.t(), Path.t(), timeout()) ::
          {:ok, query_result()} | {:error, term()}
  def snapshot_into(server, path, timeout \\ @default_query_timeout) do
    call(server, {:snapshot_into, path}, timeout)
  end

  @doc """
  Whether the connection is in autocommit mode from `owner`'s point of
  view: false only while `owner` itself holds the writer lease.
  """
  @spec autocommit?(pid() | String.t(), pid() | nil, timeout()) :: boolean()
  def autocommit?(server, owner, timeout \\ @default_query_timeout) do
    case call(server, {:autocommit?, owner}, timeout) do
      value when is_boolean(value) -> value
      {:error, _reason} -> true
    end
  end

  @doc """
  Applies freshly resolved limits to a running server (push-to-hot):
  the size cap re-applies immediately, the idle TTL takes effect from
  the next statement. `max_hot_ms` stays as armed at activation.
  """
  @spec set_limits(pid() | String.t(), Smolsqls.Limits.t()) :: :ok | {:error, term()}
  def set_limits(server, limits) do
    call(server, {:set_limits, limits}, @default_query_timeout)
  end

  defp call(pid, request, timeout) when is_pid(pid) do
    do_call(pid, request, timeout)
  end

  defp call(database_id, request, timeout) when is_binary(database_id) do
    do_call(Registry.via(database_id), request, timeout)
  end

  defp do_call(server, request, timeout) do
    GenServer.call(server, request, timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :query_timeout}
    :exit, {:normal, {GenServer, :call, _}} -> {:error, :database_not_running}
    :exit, {:noproc, {GenServer, :call, _}} -> {:error, :database_not_running}
    :exit, {{:shutdown, _}, {GenServer, :call, _}} -> {:error, :database_not_running}
  end

  @spec database_id(pid()) :: {:ok, String.t()} | {:error, term()}
  def database_id(pid) when is_pid(pid) do
    {:ok, GenServer.call(pid, :database_id, :timer.seconds(5))}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec stop(String.t()) :: :ok
  def stop(database_id) do
    case Registry.whereis(database_id) do
      pid when is_pid(pid) -> GenServer.stop(pid, :normal)
      :undefined -> :ok
    end
  end

  @doc """
  Stops the server through the same path as an idle timeout: the
  snapshot ships first when needed. Used by drains to hand off hot
  databases.
  """
  @spec idle_stop(pid() | String.t()) :: :ok
  def idle_stop(pid) when is_pid(pid) do
    GenServer.call(pid, :idle_stop, :timer.minutes(2))
  end

  def idle_stop(database_id) when is_binary(database_id) do
    case Registry.whereis(database_id) do
      pid when is_pid(pid) -> idle_stop(pid)
      :undefined -> :ok
    end
  end

  @impl true
  def init(opts) do
    database_id = Keyword.fetch!(opts, :database_id)
    file_path = Keyword.fetch!(opts, :file_path)
    limits = Smolsqls.Limits.resolve(Keyword.get(opts, :database))
    idle_ttl = Keyword.get(opts, :idle_ttl) || limits.idle_ttl_ms || default_idle_ttl()

    File.mkdir_p!(Path.dirname(file_path))

    case Sqlite3.open(file_path) do
      {:ok, conn} ->
        :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
        :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")
        :ok = Sqlite3.set_busy_timeout(conn, :timer.seconds(5))
        :ok = Sqlite3.enable_load_extension(conn, false)
        :ok = apply_max_size(conn, limits.max_size_bytes)

        if limits.max_hot_ms do
          Process.send_after(self(), :max_hot_elapsed, limits.max_hot_ms)
        end

        state = %{
          database_id: database_id,
          file_path: file_path,
          conn: conn,
          idle_ttl: idle_ttl,
          limits: limits,
          database: Keyword.get(opts, :database),
          dirty: true,
          clean_shutdown: false,
          txn_owner: nil,
          txn_timer: nil,
          txn_monitor: nil
        }

        {:ok, state, {:continue, :register_replication}}

      {:error, reason} ->
        {:stop, {:sqlite_open_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:register_replication, state) do
    if replicated?(state), do: Smolsqls.DataPlane.Litestream.register(state.database)
    {:noreply, state, state.idle_ttl}
  end

  @impl true
  def handle_call({:query, sql, args, owner}, _from, state) do
    if lease_blocks?(state, owner) do
      {:reply, {:error, :database_busy_in_transaction}, state, state.idle_ttl}
    else
      result = with_authorizer(state.conn, fn -> run_query_with_cap(state, sql, args) end)
      state = sync_lease(state, owner)
      {:reply, result, state, state.idle_ttl}
    end
  end

  def handle_call({:describe, sql, owner}, _from, state) do
    if lease_blocks?(state, owner) do
      {:reply, {:error, :database_busy_in_transaction}, state, state.idle_ttl}
    else
      result = with_authorizer(state.conn, fn -> describe_statement(state.conn, sql) end)
      {:reply, result, state, state.idle_ttl}
    end
  end

  def handle_call({:sequence, sql, owner}, _from, state) do
    if lease_blocks?(state, owner) do
      {:reply, {:error, :database_busy_in_transaction}, state, state.idle_ttl}
    else
      result =
        with_authorizer(state.conn, fn ->
          case Sqlite3.execute(state.conn, sql) do
            :ok -> :ok
            {:error, reason} -> {:error, format_error(reason)}
          end
        end)

      state = sync_lease(state, owner)
      {:reply, result, state, state.idle_ttl}
    end
  end

  def handle_call({:snapshot_into, path}, _from, state) do
    if lease_blocks?(state, nil) do
      {:reply, {:error, :database_busy_in_transaction}, state, state.idle_ttl}
    else
      {:reply, run_query(state.conn, "VACUUM INTO ?", [path]), state, state.idle_ttl}
    end
  end

  def handle_call({:autocommit?, owner}, _from, state) do
    {:reply, state.txn_owner == nil or state.txn_owner != owner, state, state.idle_ttl}
  end

  def handle_call(:database_id, _from, state) do
    {:reply, state.database_id, state, state.idle_ttl}
  end

  def handle_call({:set_limits, limits}, _from, state) do
    :ok = apply_max_size(state.conn, limits.max_size_bytes)
    idle_ttl = limits.idle_ttl_ms || default_idle_ttl()
    state = %{state | limits: limits, idle_ttl: idle_ttl}
    {:reply, :ok, state, state.idle_ttl}
  end

  def handle_call(:idle_stop, _from, state) do
    {:stop, :normal, :ok, shutdown(state)}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, shutdown(state)}
  end

  def handle_info(:max_hot_elapsed, state) do
    {:stop, :normal, shutdown(state)}
  end

  def handle_info({:txn_timeout, timer}, %{txn_timer: timer} = state) do
    Logger.warning("transaction lease on #{state.database_id} timed out; rolling back")
    {:noreply, rollback_lease(state), state.idle_ttl}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{txn_monitor: monitor} = state) do
    Logger.warning("transaction owner on #{state.database_id} died; rolling back")
    {:noreply, rollback_lease(state), state.idle_ttl}
  end

  def handle_info(_message, state) do
    {:noreply, state, state.idle_ttl}
  end

  @impl true
  def terminate(_reason, %{conn: conn} = state) do
    Sqlite3.close(conn)
    if state.clean_shutdown, do: IdleSnapshots.touch_marker(state.file_path)
  end

  defp shutdown(state) do
    state = rollback_lease(state)
    state = ship_if_needed(state)
    if replicated?(state), do: Smolsqls.DataPlane.Litestream.stop(state.file_path)
    %{state | clean_shutdown: not state.dirty}
  end

  defp lease_blocks?(%{txn_owner: nil}, _owner), do: false
  defp lease_blocks?(%{txn_owner: owner}, owner), do: false
  defp lease_blocks?(_state, _owner), do: true

  defp sync_lease(state, owner) do
    case Sqlite3.transaction_status(state.conn) do
      {:ok, :transaction} when is_pid(owner) -> renew_lease(state, owner)
      {:ok, :transaction} -> rollback_lease(%{state | txn_owner: :ownerless})
      {:ok, :idle} -> release_lease(state)
    end
  end

  defp renew_lease(state, owner) do
    monitor =
      if state.txn_owner == owner do
        state.txn_monitor
      else
        Process.monitor(owner)
      end

    timeout = state.limits.txn_timeout_ms || :timer.seconds(5)
    timer = make_ref()
    Process.send_after(self(), {:txn_timeout, timer}, timeout)

    %{state | txn_owner: owner, txn_timer: timer, txn_monitor: monitor}
  end

  defp rollback_lease(%{txn_owner: nil} = state), do: state

  defp rollback_lease(state) do
    case Sqlite3.transaction_status(state.conn) do
      {:ok, :transaction} -> run_query(state.conn, "ROLLBACK", [])
      {:ok, :idle} -> :ok
    end

    release_lease(state)
  end

  defp release_lease(%{txn_owner: nil} = state), do: state

  defp release_lease(state) do
    if is_reference(state.txn_monitor) do
      Process.demonitor(state.txn_monitor, [:flush])
    end

    %{state | txn_owner: nil, txn_timer: nil, txn_monitor: nil}
  end

  defp ship_if_needed(%{database: %Database{}} = state) do
    started = System.monotonic_time(:millisecond)

    case ship_snapshot(state) do
      {:ok, updated} ->
        Smolsqls.Telemetry.ship(System.monotonic_time(:millisecond) - started, :ok)
        %{state | dirty: false, database: updated}

      {:error, reason} ->
        Smolsqls.Telemetry.ship(System.monotonic_time(:millisecond) - started, :error)
        Logger.warning("idle snapshot ship failed for #{state.database_id}: #{inspect(reason)}")

        state
    end
  end

  defp ship_if_needed(state), do: state

  defp ship_snapshot(state) do
    snapshot_path =
      Path.join(
        System.tmp_dir!(),
        "smolsqls-idle-#{state.database_id}-#{System.unique_integer([:positive])}.db"
      )

    try do
      with {:ok, _} <- run_query(state.conn, "VACUUM INTO ?", [snapshot_path]) do
        IdleSnapshots.ship(%{state.database | file_path: state.file_path}, snapshot_path)
      end
    after
      File.rm(snapshot_path)
    end
  end

  defp replicated?(%{database: %{litestream_enabled: true}}), do: true
  defp replicated?(_state), do: false

  defp apply_max_size(_conn, nil), do: :ok

  defp apply_max_size(conn, max_size_bytes) do
    with {:ok, %{rows: [[page_size]]}} <- run_query(conn, "PRAGMA page_size", []) do
      max_page_count = max(div(max_size_bytes, page_size), 1)
      Sqlite3.execute(conn, "PRAGMA max_page_count = #{max_page_count}")
    end
  end

  defp with_authorizer(conn, fun) do
    :ok = Sqlite3.set_authorizer(conn, @denied_authorizer_actions)

    try do
      fun.()
    after
      Sqlite3.set_authorizer(conn, [])
    end
  end

  defp run_query_with_cap(%{limits: %{statement_timeout_ms: nil}} = state, sql, args) do
    run_query(state.conn, sql, args)
  end

  defp run_query_with_cap(state, sql, args) do
    canceller = spawn(canceller(self(), state.conn, state.limits.statement_timeout_ms))

    try do
      run_query(state.conn, sql, args)
    after
      send(canceller, :statement_finished)
    end
  end

  # exqlite clears its cancel flag when a statement starts, so a
  # one-shot signal that fires before the first step is lost — the
  # canceller re-fires every interval until the statement finishes
  # (worst-case abort ≈ 2× the cap). It also monitors the server: a
  # server killed mid-statement can't outlive its own cap, because
  # dirty NIFs keep running after their process dies.
  defp canceller(server, conn, cap_ms) do
    fn ->
      monitor = Process.monitor(server)
      canceller_loop(monitor, conn, cap_ms)
    end
  end

  defp canceller_loop(monitor, conn, cap_ms) do
    receive do
      :statement_finished ->
        :ok

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        Sqlite3.cancel(conn)
    after
      cap_ms ->
        Sqlite3.cancel(conn)
        canceller_loop(monitor, conn, cap_ms)
    end
  end

  defp default_idle_ttl do
    Application.get_env(:smolsqls, :database_idle_ttl, :timer.hours(1))
  end

  defp describe_statement(conn, sql) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql),
         {:ok, columns} <- Sqlite3.columns(conn, statement) do
      param_count =
        case Sqlite3.bind_parameter_count(statement) do
          count when is_integer(count) -> count
          {:error, _} -> 0
        end

      Sqlite3.release(conn, statement)
      {:ok, %{columns: columns, param_count: param_count}}
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp run_query(conn, sql, args) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql),
         :ok <- bind_args(statement, args),
         {:ok, columns} <- Sqlite3.columns(conn, statement),
         {:ok, rows} <- Sqlite3.fetch_all(conn, statement),
         {:ok, num_changes} <- Sqlite3.changes(conn),
         {:ok, last_insert_rowid} <- Sqlite3.last_insert_rowid(conn) do
      Sqlite3.release(conn, statement)

      {:ok,
       %{
         columns: columns,
         rows: rows,
         num_changes: num_changes,
         last_insert_rowid: last_insert_rowid
       }}
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  defp bind_args(statement, args) when is_map(args) do
    named =
      Map.new(args, fn {name, value} -> {resolve_param_name(statement, name), value} end)

    Sqlite3.bind(statement, named)
  end

  defp bind_args(statement, args), do: Sqlite3.bind(statement, args)

  defp resolve_param_name(statement, name) do
    if String.starts_with?(name, [":", "@", "$"]) do
      name
    else
      Enum.find([":#{name}", "@#{name}", "$#{name}"], name, fn candidate ->
        Exqlite.Sqlite3NIF.bind_parameter_index(statement, candidate) > 0
      end)
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
