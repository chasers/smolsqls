defmodule Sqlites.Repo.Migrations.CreateAuthTokens do
  use Ecto.Migration

  def up do
    create table(:database_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :database_id, references(:databases, type: :binary_id, on_delete: :delete_all),
        null: false

      add :token_hash, :string, null: false
      add :token_ciphertext, :binary, null: false
      add :name, :string
      add :enabled, :boolean, null: false, default: true
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:database_tokens, [:token_hash])
    create index(:database_tokens, [:database_id])

    create table(:tenant_api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :token_hash, :string, null: false
      add :token_ciphertext, :binary, null: false
      add :name, :string
      add :enabled, :boolean, null: false, default: true
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenant_api_keys, [:token_hash])
    create index(:tenant_api_keys, [:tenant_id])

    flush()

    backfill("databases", "auth_token", "database_tokens", "database_id")
    backfill("tenants", "api_key", "tenant_api_keys", "tenant_id")

    alter table(:databases) do
      remove :auth_token
    end

    alter table(:tenants) do
      remove :api_key
    end

    execute "ALTER PUBLICATION sqlites_read_model ADD TABLE database_tokens, tenant_api_keys"
  end

  def down do
    execute "ALTER PUBLICATION sqlites_read_model DROP TABLE database_tokens, tenant_api_keys"

    alter table(:databases) do
      add :auth_token, :string
    end

    alter table(:tenants) do
      add :api_key, :string
    end

    drop table(:database_tokens)
    drop table(:tenant_api_keys)
  end

  defp backfill(source_table, secret_column, token_table, owner_column) do
    %{rows: rows} =
      repo().query!("SELECT id, #{secret_column} FROM #{source_table}")

    for [owner_id, secret] <- rows, is_binary(secret) do
      repo().query!(
        """
        INSERT INTO #{token_table}
          (id, #{owner_column}, token_hash, token_ciphertext, name, enabled, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, $3, 'default', true, now(), now())
        """,
        [owner_id, Sqlites.Secrets.hash(secret), Sqlites.Secrets.encrypt(secret)]
      )
    end

    :ok
  end
end
