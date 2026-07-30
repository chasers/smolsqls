defmodule SmolsqlsWeb.Api.AuthPlug do
  @moduledoc """
  Authenticates management API calls with a tenant API key passed as
  `Authorization: Bearer sk_...` and assigns the tenant to the conn.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Smolsqls.ControlPlane
  alias SmolsqlsWeb.Api.ErrorCode

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> api_key] <- get_req_header(conn, "authorization"),
         {:ok, tenant} <- ControlPlane.authenticate_tenant(api_key) do
      assign(conn, :current_tenant, tenant)
    else
      {:error, :metadb_unavailable} ->
        {status, code, message} = ErrorCode.classify(:metadb_unavailable)

        conn
        |> put_status(status)
        |> json(%{error: %{code: code, message: message}})
        |> halt()

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "missing or invalid API key"}})
        |> halt()
    end
  end
end
