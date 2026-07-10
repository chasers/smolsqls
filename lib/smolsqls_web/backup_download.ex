defmodule SmolsqlsWeb.BackupDownload do
  @moduledoc """
  Shared backup-download response logic for the API (Bearer) and dashboard
  (session) controllers. Fetches the backup artifact to a web-node temp file
  (gunzipped) and streams it with `send_download` — memory-bounded via
  sendfile — deleting the temp file afterward.
  """

  alias Smolsqls.Backups
  alias Smolsqls.ControlPlane.{Backup, Database}

  @content_type "application/vnd.sqlite3"

  @spec serve(Plug.Conn.t(), Database.t(), String.t()) :: Plug.Conn.t() | {:error, term()}
  def serve(conn, %Database{} = database, backup_id) do
    path =
      Path.join(
        System.tmp_dir!(),
        "smolsqls-download-#{System.unique_integer([:positive])}.db"
      )

    try do
      case Backups.fetch_to_file(database, backup_id, path) do
        {:ok, %Backup{} = backup} ->
          Phoenix.Controller.send_download(conn, {:file, path},
            filename: filename(database, backup),
            content_type: @content_type
          )

        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm(path)
    end
  end

  defp filename(%Database{name: name}, %Backup{inserted_at: at}) do
    "#{name}-#{Calendar.strftime(at, "%Y%m%d-%H%M%S")}.db"
  end
end
