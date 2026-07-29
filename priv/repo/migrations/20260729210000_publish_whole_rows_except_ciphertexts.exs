defmodule Smolsqls.Repo.Migrations.PublishWholeRowsExceptCiphertexts do
  use Ecto.Migration

  @moduledoc """
  The cache now holds whole rows rather than a hand-picked projection, so
  the feed has to carry every column — otherwise a row cached from the
  feed would differ from one loaded from Postgres.

  `token_ciphertext` stays out. It decrypts to a live secret, nothing on a
  cached path reads it, and leaving it out of the publication keeps it out
  of the replication stream as well as out of ETS.

  Column lists need Postgres 15. Below that the publication carries whole
  tables, ciphertexts included; `Smolsqls.ReadModel.Row` does not decode
  them, so they are dropped on apply rather than cached.
  """

  @credential_columns "id, %{owner}, token_hash, name, enabled, expires_at, " <>
                        "inserted_at, updated_at"

  def up, do: publish(with_column_lists?())

  def down do
    execute(fn ->
      if with_column_lists?() do
        repo().query!("""
        ALTER PUBLICATION smolsqls_read_model SET TABLE
          tenants (id, name, slug, limits, inserted_at),
          databases (id, tenant_id, status, node, region, cloud, file_path,
                     litestream_enabled, snapshot_generation, limits),
          database_tokens (id, database_id, token_hash, enabled, expires_at),
          tenant_api_keys (id, tenant_id, token_hash, enabled, expires_at)
        """)
      else
        :ok
      end
    end)
  end

  defp publish(true) do
    execute(fn ->
      repo().query!("""
      ALTER PUBLICATION smolsqls_read_model SET TABLE
        tenants,
        databases,
        database_tokens (#{credential_columns("database_id")}),
        tenant_api_keys (#{credential_columns("tenant_id")})
      """)
    end)
  end

  defp publish(false) do
    execute(fn ->
      repo().query!("""
      ALTER PUBLICATION smolsqls_read_model SET TABLE
        tenants, databases, database_tokens, tenant_api_keys
      """)
    end)
  end

  defp credential_columns(owner), do: String.replace(@credential_columns, "%{owner}", owner)

  defp with_column_lists? do
    %{rows: [[version]]} = repo().query!("SHOW server_version_num")
    String.to_integer(version) >= 150_000
  end
end
