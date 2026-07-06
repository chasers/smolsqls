defmodule Smolsqls.Repo.Migrations.AddOriginToBackups do
  use Ecto.Migration

  def change do
    alter table(:backups) do
      add :origin, :string, null: false, default: "manual"
    end
  end
end
