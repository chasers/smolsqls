defmodule SmolsqlsWeb.Hrana.PipelineController do
  @moduledoc """
  Hrana over HTTP (`POST /v2/pipeline` and `POST /v3/pipeline`) for
  `http://`/`https://` libsql URLs, browser clients, and edge runtimes.
  Every pipeline authenticates with the database auth token and
  `store_sql` is scoped to the requests of the same pipeline.

  Transactions work *within* a single pipeline request: this request
  process holds the writer lease (`owner: self()`), so `BEGIN`/`COMMIT`/
  `ROLLBACK` — including the conditional batches libSQL clients emit for
  atomic reads — run against one connection. Any transaction still open
  when the pipeline finishes is rolled back, so nothing leaks onto the
  shared connection or a reused keep-alive process. Transactions do not
  persist *across* requests: batons (server-held sessions) are not
  supported.
  """

  use SmolsqlsWeb, :controller

  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane
  alias SmolsqlsWeb.Hrana.Stmt

  def create(conn, params) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, database} <- ControlPlane.authenticate_database_by_token(token),
         :ok <- check_baton(params) do
      ctx = %{
        database: database,
        limits: Smolsqls.Limits.resolve(database),
        owner: self(),
        allow_transactions: true
      }

      try do
        {results, _sqls} =
          Enum.map_reduce(params["requests"] || [], %{}, fn request, sqls ->
            handle_request(request, sqls, ctx)
          end)

        json(conn, %{baton: nil, base_url: nil, results: results})
      after
        rollback_if_open(ctx)
      end
    else
      {:error, :baton_unsupported} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{message: "batons are not supported; transactions cannot span requests"}
        })

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{message: "invalid or missing auth token"}})
    end
  end

  defp handle_request(%{"type" => "store_sql", "sql_id" => sql_id, "sql" => sql}, sqls, _ctx) do
    {ok(%{type: "store_sql"}), Map.put(sqls, sql_id, sql)}
  end

  defp handle_request(%{"type" => "close_sql", "sql_id" => sql_id}, sqls, _ctx) do
    {ok(%{type: "close_sql"}), Map.delete(sqls, sql_id)}
  end

  defp handle_request(%{"type" => "execute", "stmt" => stmt}, sqls, ctx) do
    case Stmt.execute(stmt, sqls, ctx) do
      {:ok, result} -> {ok(%{type: "execute", result: result}), sqls}
      {:error, message} -> {error(message), sqls}
    end
  end

  defp handle_request(%{"type" => "batch", "batch" => batch}, sqls, ctx) do
    {ok(%{type: "batch", result: Stmt.batch(batch, sqls, ctx)}), sqls}
  end

  defp handle_request(%{"type" => "describe"} = request, sqls, ctx) do
    case Stmt.describe(request, sqls, ctx) do
      {:ok, result} -> {ok(%{type: "describe", result: result}), sqls}
      {:error, message} -> {error(message), sqls}
    end
  end

  defp handle_request(%{"type" => "sequence"} = request, sqls, ctx) do
    case Stmt.sequence(request, sqls, ctx) do
      :ok -> {ok(%{type: "sequence"}), sqls}
      {:error, message} -> {error(message), sqls}
    end
  end

  defp handle_request(%{"type" => "get_autocommit"}, sqls, ctx) do
    is_autocommit = DataPlane.autocommit?(ctx.database.id, ctx.owner)
    {ok(%{type: "get_autocommit", is_autocommit: is_autocommit}), sqls}
  end

  defp handle_request(%{"type" => "close"}, sqls, _ctx) do
    {ok(%{type: "close"}), sqls}
  end

  defp handle_request(request, sqls, _ctx) do
    {error("unsupported request type #{request["type"]}"), sqls}
  end

  defp rollback_if_open(ctx) do
    unless DataPlane.autocommit?(ctx.database.id, ctx.owner) do
      DataPlane.query(ctx.database.id, "ROLLBACK", [], :timer.seconds(5), ctx.owner)
    end

    :ok
  end

  defp ok(response), do: %{type: "ok", response: response}
  defp error(message), do: %{type: "error", error: %{message: message}}

  defp check_baton(%{"baton" => baton}) when is_binary(baton), do: {:error, :baton_unsupported}
  defp check_baton(_params), do: :ok

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :unauthorized}
    end
  end
end
