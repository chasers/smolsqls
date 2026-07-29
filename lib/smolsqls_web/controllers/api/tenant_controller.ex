defmodule SmolsqlsWeb.Api.TenantController do
  use SmolsqlsWeb, :controller

  alias Smolsqls.ControlPlane

  action_fallback SmolsqlsWeb.Api.FallbackController

  def create(conn, params) do
    with {:ok, tenant} <-
           ControlPlane.create_tenant(params, signup_ip: SmolsqlsWeb.ClientIP.get(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, tenant: tenant, limits: limits(tenant), include_api_key: true)
    end
  end

  def show(conn, _params) do
    tenant = conn.assigns.current_tenant
    render(conn, :show, tenant: tenant, limits: limits(tenant), include_api_key: false)
  end

  def update(conn, params) do
    with {:ok, tenant} <- ControlPlane.update_tenant(conn.assigns.current_tenant, params) do
      render(conn, :show, tenant: tenant, limits: limits(tenant), include_api_key: false)
    end
  end

  def delete(conn, _params) do
    with {:ok, _tenant} <- Smolsqls.delete_tenant(conn.assigns.current_tenant) do
      send_resp(conn, :no_content, "")
    end
  end

  defp limits(tenant) do
    {:ok, limits} = Smolsqls.Limits.resolve(nil, tenant)
    limits
  end
end
