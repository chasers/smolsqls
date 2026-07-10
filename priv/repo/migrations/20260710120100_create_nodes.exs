defmodule Smolsqls.Repo.Migrations.CreateNodes do
  use Ecto.Migration

  def change do
    create table(:nodes, primary_key: false) do
      add :node_name, :string, primary_key: true
      add :region, :string, null: false
      add :cloud, :string
      add :status, :string, null: false, default: "up"
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:nodes, [:region])
  end
end
