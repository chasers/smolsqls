defmodule SmolsqlsWeb.Api.BackupJSON do
  alias Smolsqls.ControlPlane.Backup

  def index(%{backups: backups, next: next}) do
    %{data: Enum.map(backups, &data/1), next: next}
  end

  def show(%{backup: backup}) do
    %{data: data(backup)}
  end

  defp data(%Backup{} = backup) do
    %{
      id: backup.id,
      created_at: backup.inserted_at,
      size_bytes: backup.size_bytes,
      origin: backup.origin
    }
  end
end
