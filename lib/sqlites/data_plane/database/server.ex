defmodule Sqlites.DataPlane.Database.Server do
  @moduledoc """
  Owns the single connection to one SQLite database file and serializes
  all access to it. Exactly one of these runs per database across the
  whole cluster, registered in `:syn` under the `:sqlites_databases`
  scope so any node can locate it.

  Every session is assumed dirty: idle-stop always ships a
  `VACUUM INTO` snapshot to the object store. Skipping the upload for
  read-only sessions is deliberately deferred until a proper SQL
  parser can classify statements — a misclassified write would lose
  data, so no heuristic gets to make that call. After a clean
  shutdown (successful ship) the generation sidecar is touched last,
  so the cache evictor can prove the local file has no writes newer
  than the shipped snapshot.
  """

  use GenServer, restart: :transient

  require Logger

  alias Exqlite.Sqlite3
  alias Sqlites.ControlPlane.Database
  alias Sqlites.DataPlane.IdleSnapshots
  alias Sqlites.DataPlane.Registry

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

  @type describe_result :: %{columns: [String.t()], param_count: non_neg_integer()}

  @spec query(pid() | String.t(), String.t(), [term()] | map(), timeout()) ::
          {:ok, query_result()} | {:error, term()}
  def query(server, sql, args \\ [], timeout \\ @default_query_timeout) do
    call(server, {:query, sql, args}, timeout)
  end

  @doc """
  Prepares without executing: column names and bound-parameter count,
  for Hrana `describe`.
  """
  @spec describe(pid() | String.t(), String.t(), timeout()) ::
          {:ok, describe_result()} | {:error, term()}
  def describe(server, sql, timeout \\ @default_query_timeout) do
    call(server, {:describe, sql}, timeout)
  end

  @doc """
  Executes a multi-statement SQL script (Hrana `sequence`); no results
  are returned. Always marks the session dirty.
  """
  @spec sequence(pid() | String.t(), String.t(), timeout()) :: :ok | {:error, term()}
  def sequence(server, sql, timeout \\ @default_query_timeout) do
    call(server, {:sequence, sql}, timeout)
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
    limits = Sqlites.Limits.resolve(Keyword.get(opts, :database))
    idle_ttl = Keyword.get(opts, :idle_ttl) || limits.idle_ttl_ms || default_idle_ttl()

    File.mkdir_p!(Path.dirname(file_path))

    case Sqlite3.open(file_path) do
      {:ok, conn} ->
        :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
        :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")
        :ok = Sqlite3.set_busy_timeout(conn, :timer.seconds(5))
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
          clean_shutdown: false
        }

        {:ok, state, {:continue, :register_replication}}

      {:error, reason} ->
        {:stop, {:sqlite_open_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:register_replication, state) do
    if replicated?(state), do: Sqlites.DataPlane.Litestream.register(state.database)
    {:noreply, state, state.idle_ttl}
  end

  @impl true
  def handle_call({:query, sql, args}, _from, state) do
    {:reply, run_query_with_cap(state, sql, args), state, state.idle_ttl}
  end

  def handle_call({:describe, sql}, _from, state) do
    {:reply, describe_statement(state.conn, sql), state, state.idle_ttl}
  end

  def handle_call({:sequence, sql}, _from, state) do
    case Sqlite3.execute(state.conn, sql) do
      :ok -> {:reply, :ok, state, state.idle_ttl}
      {:error, reason} -> {:reply, {:error, format_error(reason)}, state, state.idle_ttl}
    end
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

  def handle_info(_message, state) do
    {:noreply, state, state.idle_ttl}
  end

  @impl true
  def terminate(_reason, %{conn: conn} = state) do
    Sqlite3.close(conn)
    if state.clean_shutdown, do: IdleSnapshots.touch_marker(state.file_path)
  end

  defp shutdown(state) do
    state = ship_if_needed(state)
    if replicated?(state), do: Sqlites.DataPlane.Litestream.stop(state.file_path)
    %{state | clean_shutdown: not state.dirty}
  end

  defp ship_if_needed(%{database: %Database{}} = state) do
    case ship_snapshot(state) do
      {:ok, updated} ->
        %{state | dirty: false, database: updated}

      {:error, reason} ->
        Logger.warning("idle snapshot ship failed for #{state.database_id}: #{inspect(reason)}")

        state
    end
  end

  defp ship_if_needed(state), do: state

  defp ship_snapshot(state) do
    snapshot_path =
      Path.join(
        System.tmp_dir!(),
        "sqlites-idle-#{state.database_id}-#{System.unique_integer([:positive])}.db"
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

  defp run_query_with_cap(%{limits: %{statement_timeout_ms: nil}} = state, sql, args) do
    run_query(state.conn, sql, args)
  end

  defp run_query_with_cap(state, sql, args) do
    {:ok, timer} =
      :timer.apply_after(state.limits.statement_timeout_ms, Sqlite3, :interrupt, [state.conn])

    try do
      run_query(state.conn, sql, args)
    after
      :timer.cancel(timer)
    end
  end

  defp default_idle_ttl do
    Application.get_env(:sqlites, :database_idle_ttl, :timer.hours(1))
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
