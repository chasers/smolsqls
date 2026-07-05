defmodule SqlitesWeb.Hrana.Socket do
  @moduledoc """
  WebSocket handler speaking a subset of the Hrana protocol (v1/v2)
  used by libSQL clients: `hello`, `open_stream`, `close_stream`,
  `execute`, `batch`, `store_sql`, `describe`, `sequence`. The
  database is identified by the per-database auth token carried in
  `hello`, so clients can connect to any host/path the cluster serves.
  Statements are routed to the owning node through `Sqlites.DataPlane`;
  execution itself lives in `SqlitesWeb.Hrana.Stmt`, shared with the
  HTTP pipeline.
  """

  @behaviour WebSock

  alias Sqlites.ControlPlane
  alias SqlitesWeb.Hrana.Stmt

  @impl true
  def init(_opts) do
    {:ok, %{database: nil, limits: nil, streams: MapSet.new(), sqls: %{}}}
  end

  @impl true
  def handle_in({payload, opcode: :text}, state) do
    case Jason.decode(payload) do
      {:ok, message} -> handle_message(message, state)
      {:error, _} -> {:stop, :normal, 1003, state}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp handle_message(%{"type" => "hello"} = message, state) do
    token = message["jwt"]

    case token && ControlPlane.authenticate_database_by_token(token) do
      {:ok, database} ->
        limits = Sqlites.Limits.resolve(database)
        reply(%{type: "hello_ok"}, %{state | database: database, limits: limits})

      _ ->
        reply(
          %{type: "hello_error", error: %{message: "invalid auth token", code: "AUTH_INVALID"}},
          state
        )
    end
  end

  defp handle_message(%{"type" => "request"} = message, %{database: nil} = state) do
    request_error(message["request_id"], "hello with a valid auth token required", state)
  end

  defp handle_message(
         %{"type" => "request", "request_id" => request_id, "request" => request},
         state
       ) do
    handle_request(request, request_id, state)
  end

  defp handle_message(_message, state), do: {:ok, state}

  defp handle_request(%{"type" => "open_stream", "stream_id" => stream_id}, request_id, state) do
    state = %{state | streams: MapSet.put(state.streams, stream_id)}
    respond_ok(request_id, %{type: "open_stream"}, state)
  end

  defp handle_request(%{"type" => "close_stream", "stream_id" => stream_id}, request_id, state) do
    state = %{state | streams: MapSet.delete(state.streams, stream_id)}
    respond_ok(request_id, %{type: "close_stream"}, state)
  end

  defp handle_request(
         %{"type" => "store_sql", "sql_id" => sql_id, "sql" => sql},
         request_id,
         state
       ) do
    state = %{state | sqls: Map.put(state.sqls, sql_id, sql)}
    respond_ok(request_id, %{type: "store_sql"}, state)
  end

  defp handle_request(%{"type" => "close_sql", "sql_id" => sql_id}, request_id, state) do
    state = %{state | sqls: Map.delete(state.sqls, sql_id)}
    respond_ok(request_id, %{type: "close_sql"}, state)
  end

  defp handle_request(%{"type" => "get_autocommit"}, request_id, state) do
    respond_ok(request_id, %{type: "get_autocommit", is_autocommit: true}, state)
  end

  defp handle_request(%{"type" => "execute", "stmt" => stmt}, request_id, state) do
    case Stmt.execute(stmt, state.sqls, state.database, state.limits) do
      {:ok, result} -> respond_ok(request_id, %{type: "execute", result: result}, state)
      {:error, message} -> request_error(request_id, message, state)
    end
  end

  defp handle_request(%{"type" => "batch", "batch" => batch}, request_id, state) do
    result = Stmt.batch(batch, state.sqls, state.database, state.limits)
    respond_ok(request_id, %{type: "batch", result: result}, state)
  end

  defp handle_request(%{"type" => "describe"} = request, request_id, state) do
    case Stmt.describe(request, state.sqls, state.database, state.limits) do
      {:ok, result} -> respond_ok(request_id, %{type: "describe", result: result}, state)
      {:error, message} -> request_error(request_id, message, state)
    end
  end

  defp handle_request(%{"type" => "sequence"} = request, request_id, state) do
    case Stmt.sequence(request, state.sqls, state.database, state.limits) do
      :ok -> respond_ok(request_id, %{type: "sequence"}, state)
      {:error, message} -> request_error(request_id, message, state)
    end
  end

  defp handle_request(request, request_id, state) do
    request_error(request_id, "unsupported request type #{request["type"]}", state)
  end

  defp respond_ok(request_id, response, state) do
    reply(%{type: "response_ok", request_id: request_id, response: response}, state)
  end

  defp request_error(request_id, message, state) do
    reply(
      %{type: "response_error", request_id: request_id, error: %{message: message}},
      state
    )
  end

  defp reply(message, state) do
    {:push, {:text, Jason.encode!(message)}, state}
  end
end
