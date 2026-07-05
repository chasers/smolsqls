defmodule Sqlites.Repo.Migrations.CreateNodeDrains do
  use Ecto.Migration

  def up do
    create table(:node_drains, primary_key: false) do
      add :node, :string, primary_key: true
      add :requested_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :started_by, :string
      add :completed_at, :utc_datetime_usec
      add :reassigned, :integer
      add :error, :string
    end
  end

  def down do
    drop table(:node_drains)
  end
end
