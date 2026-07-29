defmodule Smolsqls.Repo.Migrations.NarrowReadModelPublication do
  use Ecto.Migration

  @moduledoc """
  Narrows the read-model feed to what the query-path cache holds:
  `tenant_api_keys` leaves the publication entirely (management auth
  reads Postgres directly), and on Postgres 15+ each remaining table is
  published with only its projected columns.

  `database_tokens` also moves its replica identity onto the
  `token_hash` unique index, because that is the key the cache stores it
  under. A delete event then carries the hash, so a revocation applies
  without every node keeping an id-to-hash index.

  Column lists in publications need Postgres 15 (deployments run 17, CI
  runs 16, some dev machines are older). Where they are unavailable the
  feed simply carries columns the cache ignores, so the migration logs
  and moves on rather than failing.
  """

  @databases "id, tenant_id, status, node, region, cloud, file_path, " <>
               "litestream_enabled, snapshot_generation, limits"
  @database_tokens "id, database_id, token_hash, enabled, expires_at"

  def up do
    execute """
    ALTER TABLE database_tokens
      REPLICA IDENTITY USING INDEX database_tokens_token_hash_index
    """

    execute "ALTER PUBLICATION smolsqls_read_model DROP TABLE tenant_api_keys"

    execute(fn ->
      if column_lists_supported?() do
        repo().query!("""
        ALTER PUBLICATION smolsqls_read_model SET TABLE
          tenants (id, limits),
          databases (#{@databases}),
          database_tokens (#{@database_tokens})
        """)
      else
        IO.puts(
          "[read model] Postgres < 15: publishing all columns; " <>
            "the cache projects them away on apply"
        )
      end
    end)
  end

  def down do
    execute(fn ->
      repo().query!("""
      ALTER PUBLICATION smolsqls_read_model SET TABLE
        tenants, databases, database_tokens
      """)
    end)

    execute "ALTER PUBLICATION smolsqls_read_model ADD TABLE tenant_api_keys"
    execute "ALTER TABLE database_tokens REPLICA IDENTITY DEFAULT"
  end

  defp column_lists_supported? do
    %{rows: [[version]]} = repo().query!("SHOW server_version_num")
    String.to_integer(version) >= 150_000
  end
end
