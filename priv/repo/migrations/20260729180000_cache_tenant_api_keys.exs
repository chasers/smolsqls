defmodule Smolsqls.Repo.Migrations.CacheTenantApiKeys do
  use Ecto.Migration

  @moduledoc """
  Brings `tenant_api_keys` back into the read-model feed, now that the
  cache holds a working set rather than a full replica: caching them is
  bounded by the keys actually in use, so management auth resolves a
  caller without reading Postgres.

  Its replica identity moves to the `token_hash` unique index for the same
  reason `database_tokens`' did — that is the key the cache stores it
  under, so a delete event carries the hash and a revocation applies
  without an id-to-hash index on every node.

  The `tenants` column list widens to the fields management responses
  render (`name`, `slug`, `inserted_at`), so a cached tenant is
  renderable and mgmt auth needs no second lookup.

  Column lists in publications need Postgres 15; where unavailable the
  feed carries columns the cache projects away on apply.
  """

  @databases "id, tenant_id, status, node, region, cloud, file_path, " <>
               "litestream_enabled, snapshot_generation, limits"
  @database_tokens "id, database_id, token_hash, enabled, expires_at"
  @tenant_api_keys "id, tenant_id, token_hash, enabled, expires_at"
  @tenants "id, name, slug, limits, inserted_at"

  def up do
    execute """
    ALTER TABLE tenant_api_keys
      REPLICA IDENTITY USING INDEX tenant_api_keys_token_hash_index
    """

    execute(fn ->
      if column_lists_supported?() do
        repo().query!("""
        ALTER PUBLICATION smolsqls_read_model SET TABLE
          tenants (#{@tenants}),
          databases (#{@databases}),
          database_tokens (#{@database_tokens}),
          tenant_api_keys (#{@tenant_api_keys})
        """)
      else
        repo().query!("ALTER PUBLICATION smolsqls_read_model ADD TABLE tenant_api_keys")
      end
    end)
  end

  def down do
    execute(fn ->
      if column_lists_supported?() do
        repo().query!("""
        ALTER PUBLICATION smolsqls_read_model SET TABLE
          tenants (id, limits),
          databases (#{@databases}),
          database_tokens (#{@database_tokens})
        """)
      else
        repo().query!("ALTER PUBLICATION smolsqls_read_model DROP TABLE tenant_api_keys")
      end
    end)

    execute "ALTER TABLE tenant_api_keys REPLICA IDENTITY DEFAULT"
  end

  defp column_lists_supported? do
    %{rows: [[version]]} = repo().query!("SHOW server_version_num")
    String.to_integer(version) >= 150_000
  end
end
