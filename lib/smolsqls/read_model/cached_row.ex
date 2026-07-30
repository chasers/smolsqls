defmodule Smolsqls.ReadModel.CachedRow do
  @moduledoc """
  What a cached row contains: **every column the schema has**, minus the
  credential ciphertexts.

  Rows are cached whole so nothing downstream has to know, or care, which
  fields came from the cache — a cached row reads exactly like one loaded
  from Postgres. The alternative (caching only the columns the query path
  reads) saved memory the working-set cache no longer needs to save, and
  cost every reader an invisible rule about which fields might be `nil`.

  The one exception is the credentials on the credential tables:
  `token_ciphertext` decrypts to a live secret, and the virtual `token`
  field *is* the plaintext secret on the create path. Nothing on a cached
  path reads either (`reveal` goes to Postgres), and caching them would
  leave the secret in ETS on every node that ever created or
  authenticated that token — and in any crash dump taken there.
  `token_ciphertext` is excluded from the publication too, so it never
  enters the replication stream; `token` is virtual and never leaves the
  creating process except through the create response.

  Cached rows are still **read-only**: an entry can be stale, so writes go
  to Postgres by id rather than re-writing a whole row from cache.
  """

  @redacted %{
    database_tokens: [:token, :token_ciphertext],
    tenant_api_keys: [:token, :token_ciphertext]
  }

  @doc """
  The fields the cache holds for a table — all of the schema's, minus any
  redacted ones. `Smolsqls.ReadModel.Source` selects exactly these, so a
  redacted column is never even transferred out of Postgres.
  """
  @spec fields(module(), Smolsqls.ReadModel.table()) :: [atom()]
  def fields(schema, table), do: schema.__schema__(:fields) -- redacted(table)

  @spec redacted(Smolsqls.ReadModel.table()) :: [atom()]
  def redacted(table), do: Map.get(@redacted, table, [])

  @doc """
  Clears the redacted fields on a row the caller already has in full —
  the write-through path, which caches the row it just wrote to Postgres.
  """
  @spec narrow(Smolsqls.ReadModel.table(), struct()) :: struct()
  def narrow(table, row) do
    case redacted(table) do
      [] -> row
      fields -> Map.merge(row, Map.new(fields, &{&1, nil}))
    end
  end
end
