defmodule Sqlites.Repo.Migrations.AddSnapshotGenerationToDatabases do
  use Ecto.Migration

  def up do
    alter table(:databases) do
      add :snapshot_generation, :bigint, null: false, default: 0
      add :last_snapshot_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:databases) do
      remove :snapshot_generation
      remove :last_snapshot_at
    end
  end
end
