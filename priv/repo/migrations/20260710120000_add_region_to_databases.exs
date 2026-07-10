defmodule Smolsqls.Repo.Migrations.AddRegionToDatabases do
  use Ecto.Migration

  def up do
    alter table(:databases) do
      add :region, :string
      add :cloud, :string
    end

    create index(:databases, [:region])
    create index(:databases, [:cloud])
  end

  def down do
    alter table(:databases) do
      remove :region
      remove :cloud
    end
  end
end
