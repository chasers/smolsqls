defmodule SqlitesWeb.Api.TenantApiKeyController do
  use SqlitesWeb, :controller

  alias Sqlites.ControlPlane

  plug :put_view, json: SqlitesWeb.Api.TokenJSON

  action_fallback SqlitesWeb.Api.FallbackController

  def index(conn, _params) do
    keys = ControlPlane.list_tenant_api_keys(conn.assigns.current_tenant)
    render(conn, :index, tokens: keys)
  end

  def create(conn, params) do
    with {:ok, key} <- ControlPlane.create_tenant_api_key(conn.assigns.current_tenant, params) do
      conn
      |> put_status(:created)
      |> render(:show, token: key)
    end
  end

  def reveal(conn, %{"id" => id}) do
    with {:ok, key} <- fetch_key(conn, id),
         {:ok, key} <- ControlPlane.reveal(key) do
      render(conn, :show, token: key)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, key} <- fetch_key(conn, id),
         {:ok, key} <- ControlPlane.update_tenant_api_key(key, params) do
      render(conn, :show, token: key)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, key} <- fetch_key(conn, id),
         {:ok, _key} <- ControlPlane.delete_tenant_api_key(key) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch_key(conn, id) do
    case ControlPlane.get_tenant_api_key(conn.assigns.current_tenant, id) do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end
end
