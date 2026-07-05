defmodule SqlitesWeb.Api.DatabaseTokenController do
  use SqlitesWeb, :controller

  alias Sqlites.ControlPlane

  plug :put_view, json: SqlitesWeb.Api.TokenJSON

  action_fallback SqlitesWeb.Api.FallbackController

  def index(conn, %{"database_id" => database_id}) do
    with {:ok, database} <- fetch_database(conn, database_id) do
      render(conn, :index, tokens: ControlPlane.list_database_tokens(database))
    end
  end

  def create(conn, %{"database_id" => database_id} = params) do
    with {:ok, database} <- fetch_database(conn, database_id),
         {:ok, token} <- ControlPlane.create_database_token(database, params) do
      conn
      |> put_status(:created)
      |> render(:show, token: token)
    end
  end

  def reveal(conn, %{"database_id" => database_id, "id" => id}) do
    with {:ok, database} <- fetch_database(conn, database_id),
         {:ok, token} <- fetch_token(database, id),
         {:ok, token} <- ControlPlane.reveal(token) do
      render(conn, :show, token: token)
    end
  end

  def update(conn, %{"database_id" => database_id, "id" => id} = params) do
    with {:ok, database} <- fetch_database(conn, database_id),
         {:ok, token} <- fetch_token(database, id),
         {:ok, token} <- ControlPlane.update_database_token(token, params) do
      render(conn, :show, token: token)
    end
  end

  def delete(conn, %{"database_id" => database_id, "id" => id}) do
    with {:ok, database} <- fetch_database(conn, database_id),
         {:ok, token} <- fetch_token(database, id),
         {:ok, _token} <- ControlPlane.delete_database_token(token) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch_database(conn, id) do
    case ControlPlane.get_database(conn.assigns.current_tenant, id) do
      nil -> {:error, :not_found}
      database -> {:ok, database}
    end
  end

  defp fetch_token(database, id) do
    case ControlPlane.get_database_token(database, id) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end
end
