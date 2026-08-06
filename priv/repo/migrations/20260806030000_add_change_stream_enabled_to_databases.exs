defmodule Smolsqls.Repo.Migrations.AddChangeStreamEnabledToDatabases do
  use Ecto.Migration

  def change do
    alter table(:databases) do
      add :change_stream_enabled, :boolean, null: false, default: true
    end
  end
end
