defmodule Smolsqls.Repo.Migrations.RekeyReadModelFeedForTheCache do
  use Ecto.Migration

  @moduledoc """
  Adapts the read-model feed to the bounded read-through cache in a
  single step, so old-code nodes streaming through a rolling deploy
  never see an intermediate publication shape. The end state is the
  only state: whole rows for every cached table, minus the credential
  ciphertexts — every column old `Row.build_*` decoders `fetch!` stays
  published throughout.

  `token_ciphertext` stays out of the publication: it decrypts to a
  live secret, nothing on a cached path reads it, and leaving it out of
  the stream keeps it out of ETS on every node. Column lists need
  Postgres 15 (deployments run 17, CI 16, some dev machines are older);
  below that the publication carries whole tables, ciphertexts
  included, and `Smolsqls.ReadModel.Row` drops them on apply rather
  than caching them.

  Both credential tables move their replica identity onto the
  `token_hash` unique index — the key the cache stores them under — so
  a delete event carries the hash and a revocation applies without an
  id-to-hash index on every node. Known window: deletes replicated
  after this migration carry `token_hash` instead of `id`, which
  not-yet-upgraded nodes ignore, so a revocation mid-rollout reaches an
  old node only once it upgrades.
  """

  @credential_columns "id, %{owner}, token_hash, name, enabled, expires_at, " <>
                        "inserted_at, updated_at"

  def up do
    execute """
    ALTER TABLE database_tokens
      REPLICA IDENTITY USING INDEX database_tokens_token_hash_index
    """

    execute """
    ALTER TABLE tenant_api_keys
      REPLICA IDENTITY USING INDEX tenant_api_keys_token_hash_index
    """

    execute(fn ->
      if column_lists_supported?() do
        repo().query!("""
        ALTER PUBLICATION smolsqls_read_model SET TABLE
          tenants,
          databases,
          database_tokens (#{credential_columns("database_id")}),
          tenant_api_keys (#{credential_columns("tenant_id")})
        """)
      else
        IO.puts(
          "[read model] Postgres < 15: publishing all columns; " <>
            "ciphertexts cross the stream and are dropped on apply"
        )
      end
    end)
  end

  def down do
    execute(fn ->
      if column_lists_supported?() do
        repo().query!("""
        ALTER PUBLICATION smolsqls_read_model SET TABLE
          tenants, databases, database_tokens, tenant_api_keys
        """)
      else
        :ok
      end
    end)

    execute "ALTER TABLE tenant_api_keys REPLICA IDENTITY DEFAULT"
    execute "ALTER TABLE database_tokens REPLICA IDENTITY DEFAULT"
  end

  defp credential_columns(owner), do: String.replace(@credential_columns, "%{owner}", owner)

  defp column_lists_supported? do
    %{rows: [[version]]} = repo().query!("SHOW server_version_num")
    String.to_integer(version) >= 150_000
  end
end
