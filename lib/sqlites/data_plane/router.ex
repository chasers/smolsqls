defmodule Sqlites.DataPlane.Router do
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

  alias Sqlites.ControlPlane
  alias Sqlites.DataPlane.Database.Server
  alias Sqlites.DataPlane.Registry

  @default_timeout :timer.seconds(30)
  @gen_rpc_margin :timer.seconds(5)

  @spec query(String.t(), String.t(), [term()] | map(), timeout()) ::
          {:ok, Server.query_result()} | {:error, term()}
  def query(database_id, sql, args \\ [], timeout \\ @default_timeout) do
    route(database_id, {:query, sql, args}, timeout)
  end

  @spec describe(String.t(), String.t(), timeout()) ::
          {:ok, Server.describe_result()} | {:error, term()}
  def describe(database_id, sql, timeout \\ @default_timeout) do
    route(database_id, {:describe, sql}, timeout)
  end

  @spec sequence(String.t(), String.t(), timeout()) :: :ok | {:error, term()}
  def sequence(database_id, sql, timeout \\ @default_timeout) do
    route(database_id, {:sequence, sql}, timeout)
  end

  defp route(database_id, op, timeout) do
    case Registry.owner_node(database_id) do
      {:ok, node} -> dispatch(node, database_id, op, timeout)
      {:error, :not_found} -> activate_and_dispatch(database_id, op, timeout)
    end
  end

  defp activate_and_dispatch(database_id, op, timeout) do
    with %ControlPlane.Database{} = database <- ControlPlane.lookup_database(database_id),
         {:ok, pid} <- Sqlites.DataPlane.activate_database(database) do
      dispatch(node(pid), database_id, op, timeout)
    else
      nil -> {:error, :database_not_running}
      {:error, reason} -> {:error, reason}
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

  defp call_server(pid, {:query, sql, args}, timeout), do: Server.query(pid, sql, args, timeout)
  defp call_server(pid, {:describe, sql}, timeout), do: Server.describe(pid, sql, timeout)
  defp call_server(pid, {:sequence, sql}, timeout), do: Server.sequence(pid, sql, timeout)

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
