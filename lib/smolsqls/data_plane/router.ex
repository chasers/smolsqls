defmodule Smolsqls.DataPlane.Router do
  @moduledoc """
  Routes an operation (query, describe, sequence) to whichever node
  owns the database's `Server` process. Local databases are called
  directly; remote ones go over `gen_rpc` so query/result traffic
  stays off Erlang distribution — erl_dist carries only cluster
  membership and `:syn` gossip.

  The caller-side timeout comes from the resolved per-database limits
  at the protocol edge; the `gen_rpc` envelope gets a small margin on
  top so the remote `Server` call times out first.
  """

  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane.Database.Server
  alias Smolsqls.DataPlane.Registry

  @default_timeout :timer.seconds(30)
  @gen_rpc_margin :timer.seconds(5)

  @spec query(String.t(), String.t(), [term()] | map(), timeout(), pid() | nil) ::
          {:ok, Server.query_result()} | {:error, term()}
  def query(database_id, sql, args \\ [], timeout \\ @default_timeout, owner \\ nil) do
    route(database_id, {:query, sql, args, owner}, timeout)
  end

  @spec describe(String.t(), String.t(), timeout(), pid() | nil) ::
          {:ok, Server.describe_result()} | {:error, term()}
  def describe(database_id, sql, timeout \\ @default_timeout, owner \\ nil) do
    route(database_id, {:describe, sql, owner}, timeout)
  end

  @spec sequence(String.t(), String.t(), timeout(), pid() | nil) :: :ok | {:error, term()}
  def sequence(database_id, sql, timeout \\ @default_timeout, owner \\ nil) do
    route(database_id, {:sequence, sql, owner}, timeout)
  end

  @spec snapshot_into(String.t(), Path.t(), timeout()) ::
          {:ok, Server.query_result()} | {:error, term()}
  def snapshot_into(database_id, path, timeout \\ @default_timeout) do
    route(database_id, {:snapshot_into, path}, timeout)
  end

  @spec autocommit?(String.t(), pid() | nil, timeout()) :: boolean()
  def autocommit?(database_id, owner, timeout \\ @default_timeout) do
    case Registry.owner_node(database_id) do
      {:ok, node} ->
        case dispatch(node, database_id, {:autocommit?, owner}, timeout) do
          value when is_boolean(value) -> value
          _other -> true
        end

      {:error, :not_found} ->
        true
    end
  end

  defp route(database_id, op, timeout) do
    started = System.monotonic_time(:millisecond)

    {node, result} =
      case Registry.owner_node(database_id) do
        {:ok, node} -> {node, dispatch(node, database_id, op, timeout)}
        {:error, :not_found} -> activate_and_dispatch(database_id, op, timeout)
      end

    Smolsqls.Telemetry.query(
      System.monotonic_time(:millisecond) - started,
      classify(result),
      node != nil and node != Node.self()
    )

    result
  end

  defp classify(:ok), do: :ok
  defp classify({:ok, _}), do: :ok
  defp classify({:error, {:badrpc, _}}), do: :badrpc
  defp classify({:error, {:badtcp, _}}), do: :badrpc
  defp classify(_result), do: :error

  defp activate_and_dispatch(database_id, op, timeout) do
    with %ControlPlane.Database{} = database <- ControlPlane.lookup_database(database_id),
         {:ok, pid} <- Smolsqls.DataPlane.activate_database(database) do
      {node(pid), dispatch(node(pid), database_id, op, timeout)}
    else
      nil -> {nil, {:error, :database_not_running}}
      {:error, reason} -> {nil, {:error, reason}}
    end
  end

  @doc """
  Entry point for remote nodes: executed on the owning node via
  `:gen_rpc.call/5`, where the `:syn` lookup resolves to a local pid.
  """
  @spec local_op(String.t(), tuple(), timeout()) :: term()
  def local_op(database_id, op, timeout) do
    case Registry.whereis(database_id) do
      pid when is_pid(pid) -> call_server(pid, op, timeout)
      :undefined -> {:error, :database_not_running}
    end
  end

  defp call_server(pid, {:query, sql, args, owner}, timeout) do
    Server.query(pid, sql, args, timeout, owner)
  end

  defp call_server(pid, {:describe, sql, owner}, timeout) do
    Server.describe(pid, sql, timeout, owner)
  end

  defp call_server(pid, {:sequence, sql, owner}, timeout) do
    Server.sequence(pid, sql, timeout, owner)
  end

  defp call_server(pid, {:snapshot_into, path}, timeout) do
    Server.snapshot_into(pid, path, timeout)
  end

  defp call_server(pid, {:autocommit?, owner}, timeout) do
    Server.autocommit?(pid, owner, timeout)
  end

  defp dispatch(node, database_id, op, timeout) do
    if node == Node.self() do
      local_op(database_id, op, timeout)
    else
      case :gen_rpc.call(
             node,
             __MODULE__,
             :local_op,
             [database_id, op, timeout],
             timeout + @gen_rpc_margin
           ) do
        {:badrpc, reason} -> {:error, {:badrpc, reason}}
        {:badtcp, reason} -> {:error, {:badtcp, reason}}
        result -> result
      end
    end
  end
end
