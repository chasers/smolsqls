defmodule SqlitesWeb.Hrana.PipelineController do
  @moduledoc """
  Hrana over HTTP (`POST /v2/pipeline`) for `http://` libsql URLs and
  edge runtimes. Stateless: every pipeline authenticates with the
  database auth token, `store_sql` is scoped to the requests of the
  same pipeline, and batons (server-held sessions, used for
  interactive transactions) are not supported.
  """

  use SqlitesWeb, :controller

  alias Sqlites.ControlPlane
  alias SqlitesWeb.Hrana.Stmt

  def create(conn, params) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, database} <- ControlPlane.authenticate_database_by_token(token),
         :ok <- check_baton(params) do
      limits = Sqlites.Limits.resolve(database)

      {results, _sqls} =
        Enum.map_reduce(params["requests"] || [], %{}, fn request, sqls ->
          handle_request(request, sqls, database, limits)
        end)

      json(conn, %{baton: nil, base_url: nil, results: results})
    else
      {:error, :baton_unsupported} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{message: "batons are not supported; pipelines are stateless"}})

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{message: "invalid or missing auth token"}})
    end
  end

  defp handle_request(%{"type" => "store_sql", "sql_id" => sql_id, "sql" => sql}, sqls, _db, _l) do
    {ok(%{type: "store_sql"}), Map.put(sqls, sql_id, sql)}
  end

  defp handle_request(%{"type" => "close_sql", "sql_id" => sql_id}, sqls, _db, _l) do
    {ok(%{type: "close_sql"}), Map.delete(sqls, sql_id)}
  end

  defp handle_request(%{"type" => "execute", "stmt" => stmt}, sqls, database, limits) do
    case Stmt.execute(stmt, sqls, database, limits) do
      {:ok, result} -> {ok(%{type: "execute", result: result}), sqls}
      {:error, message} -> {error(message), sqls}
    end
  end

  defp handle_request(%{"type" => "batch", "batch" => batch}, sqls, database, limits) do
    {ok(%{type: "batch", result: Stmt.batch(batch, sqls, database, limits)}), sqls}
  end

  defp handle_request(%{"type" => "describe"} = request, sqls, database, limits) do
    case Stmt.describe(request, sqls, database, limits) do
      {:ok, result} -> {ok(%{type: "describe", result: result}), sqls}
      {:error, message} -> {error(message), sqls}
    end
  end

  defp handle_request(%{"type" => "sequence"} = request, sqls, database, limits) do
    case Stmt.sequence(request, sqls, database, limits) do
      :ok -> {ok(%{type: "sequence"}), sqls}
      {:error, message} -> {error(message), sqls}
    end
  end

  defp handle_request(%{"type" => "get_autocommit"}, sqls, _db, _l) do
    {ok(%{type: "get_autocommit", is_autocommit: true}), sqls}
  end

  defp handle_request(%{"type" => "close"}, sqls, _db, _l) do
    {ok(%{type: "close"}), sqls}
  end

  defp handle_request(request, sqls, _db, _l) do
    {error("unsupported request type #{request["type"]}"), sqls}
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
