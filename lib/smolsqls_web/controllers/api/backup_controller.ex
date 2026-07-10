defmodule SmolsqlsWeb.Api.BackupController do
  use SmolsqlsWeb, :controller

  alias Smolsqls.Backups
  alias Smolsqls.ControlPlane

  action_fallback SmolsqlsWeb.Api.FallbackController

  def index(conn, %{"database_id" => database_id} = params) do
    with {:ok, database} <- fetch_database(conn, database_id),
         {:ok, page_opts} <- SmolsqlsWeb.Api.Pagination.opts(params),
         {:ok, page} <- Backups.paginate(database, page_opts) do
      render(conn, :index, backups: page.entries, next: page.next)
    end
  end

  def create(conn, %{"database_id" => database_id}) do
    with {:ok, database} <- fetch_database(conn, database_id),
         {:ok, backup} <- Backups.trigger(database) do
      conn
      |> put_status(:created)
      |> render(:show, backup: backup)
    end
  end

  def restore(conn, %{"database_id" => database_id, "backup_id" => backup_id}) do
    with {:ok, database} <- fetch_database(conn, database_id),
         :ok <- Backups.restore(database, backup_id) do
      send_resp(conn, :accepted, "")
    end
  end

  def download(conn, %{"database_id" => database_id, "backup_id" => backup_id}) do
    with {:ok, database} <- fetch_database(conn, database_id) do
      SmolsqlsWeb.BackupDownload.serve(conn, database, backup_id)
    end
  end

  defp fetch_database(conn, id) do
    case ControlPlane.get_database(conn.assigns.current_tenant, id) do
      nil -> {:error, :not_found}
      database -> {:ok, database}
    end
  end
end
