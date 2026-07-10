defmodule SmolsqlsWeb.BackupDownloadController do
  @moduledoc """
  Dashboard backup download. A browser `<a>` can't send a Bearer header, so this
  authenticates from the session API key (set at login) rather than the API's
  AuthPlug, then streams the file via the shared `BackupDownload` helper.
  """

  use SmolsqlsWeb, :controller

  alias Smolsqls.ControlPlane

  def show(conn, %{"database_id" => database_id, "backup_id" => backup_id}) do
    with api_key when is_binary(api_key) <- get_session(conn, :api_key),
         {:ok, tenant} <- ControlPlane.authenticate_tenant(api_key),
         %{} = database <- ControlPlane.get_database(tenant, database_id),
         %Plug.Conn{} = sent <-
           SmolsqlsWeb.BackupDownload.serve(conn, database, backup_id) do
      sent
    else
      _ -> conn |> put_status(:not_found) |> text("Backup not found")
    end
  end
end
