defmodule SmolsqlsWeb.SessionController do
  use SmolsqlsWeb, :controller

  alias Smolsqls.ControlPlane
  alias SmolsqlsWeb.ChangesetError

  def create(conn, %{"api_key" => api_key}) do
    case ControlPlane.authenticate_tenant(api_key) do
      {:ok, _tenant} ->
        conn
        |> put_session(:api_key, api_key)
        |> redirect(to: ~p"/dashboard")

      {:error, :unauthorized} ->
        conn
        |> put_flash(:error, "Invalid API key")
        |> redirect(to: ~p"/")
    end
  end

  def signup(conn, params) do
    case ControlPlane.create_tenant(params, signup_ip: SmolsqlsWeb.ClientIP.get(conn)) do
      {:ok, tenant} ->
        conn
        |> put_session(:api_key, tenant.api_key)
        |> put_flash(:info, "Account created. Reveal and copy your API key below to connect.")
        |> redirect(to: ~p"/account")

      {:error, :signup_rate_limited} ->
        conn
        |> put_flash(
          :error,
          "Too many accounts created from your network recently. Try again later."
        )
        |> redirect(to: ~p"/")

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Could not create tenant: #{ChangesetError.message(changeset)}")
        |> redirect(to: ~p"/")
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: ~p"/")
  end
end
