defmodule Smolsqls.Repo.Migrations.AddBranchingColumnsToDatabases do
  use Ecto.Migration

  def up do
    alter table(:databases) do
      add :source_database_id, references(:databases, type: :binary_id, on_delete: :restrict)
      add :branch_point_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
    end

    create index(:databases, [:source_database_id])
    create index(:databases, [:expires_at])
  end

  def down do
    alter table(:databases) do
      remove :source_database_id
      remove :branch_point_at
      remove :expires_at
    end
  end
end
