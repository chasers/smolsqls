defmodule Sqlites.Repo.Migrations.AddLimitsToTenantsAndDatabases do
  use Ecto.Migration

  def up do
    alter table(:tenants) do
      add :limits, :map, null: false, default: %{}
    end

    alter table(:databases) do
      add :limits, :map, null: false, default: %{}
    end
  end

  def down do
    alter table(:tenants) do
      remove :limits
    end

    alter table(:databases) do
      remove :limits
    end
  end
end
