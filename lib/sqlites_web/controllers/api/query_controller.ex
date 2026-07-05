defmodule SqlitesWeb.Api.QueryController do
  use SqlitesWeb, :controller

  alias Sqlites.ControlPlane
  alias Sqlites.DataPlane

  action_fallback SqlitesWeb.Api.FallbackController

  def create(conn, %{"database_id" => database_id, "sql" => sql} = params) do
    args = Map.get(params, "args", [])

    with {:ok, token} <- bearer_token(conn),
         {:ok, database} <- ControlPlane.authenticate_database(database_id, token),
         limits = Sqlites.Limits.resolve(database),
         :ok <- check_rate_limit(database, limits),
         :ok <- check_statement(sql),
         {:ok, result} <- DataPlane.query(database.id, sql, args, query_timeout(limits)) do
      render(conn, :show, result: result)
    end
  end

  def create(_conn, _params), do: {:error, :missing_sql}

  defp check_rate_limit(database, limits) do
    if Sqlites.RateLimiter.allow?(database.id, limits.rate_limit_rps) do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp check_statement(sql) do
    if Sqlites.DataPlane.Sql.transaction_control?(sql) do
      {:error, :transactions_not_supported}
    else
      :ok
    end
  end

  defp query_timeout(limits) do
    limits.query_timeout_ms || :timer.seconds(30)
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :unauthorized}
    end
  end
end
