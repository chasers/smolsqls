defmodule SqlitesWeb.Api.DatabaseController do
  use SqlitesWeb, :controller

  alias Sqlites.ControlPlane

  action_fallback SqlitesWeb.Api.FallbackController

  def index(conn, params) do
    with {:ok, page_opts} <- SqlitesWeb.Api.Pagination.opts(params),
         {:ok, page} <- ControlPlane.paginate_databases(conn.assigns.current_tenant, page_opts) do
      render(conn, :index, databases: page.entries, next: page.next)
    end
  end

  def create(conn, params) do
    with {:ok, database} <- Sqlites.create_database(conn.assigns.current_tenant, params) do
      conn
      |> put_status(:created)
      |> render(:show, database: database, include_token: true)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, database} <- fetch_database(conn, id) do
      render(conn, :show, database: database, include_token: true)
    end
  end

  def update(conn, %{"id" => id} = params) do
    settings = Map.take(params, ["litestream_enabled"])

    with {:ok, database} <- fetch_database(conn, id),
         {:ok, database} <- ControlPlane.update_database_settings(database, settings),
         :ok <- Sqlites.DataPlane.set_replication(database) do
      render(conn, :show, database: database, include_token: true)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, database} <- fetch_database(conn, id),
         {:ok, _database} <- Sqlites.remove_database(database) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch_database(conn, id) do
    case ControlPlane.get_database(conn.assigns.current_tenant, id) do
      nil -> {:error, :not_found}
      database -> {:ok, database}
    end
  end
end
