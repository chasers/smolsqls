defmodule Smolsqls.ReadModel.Source do
  @moduledoc """
  Postgres side of the read-model cache: the single-row read behind a
  cache miss or a refresh.

  Every read selects the columns in `Smolsqls.ReadModel.CachedRow` — the
  whole row minus credential ciphertexts — so a row loaded here is shaped
  exactly like one the WAL feed builds through `Smolsqls.ReadModel.Row`,
  and both read like a row loaded straight from Postgres.

  An unreachable metadb is reported as `{:error, :metadb_unavailable}`
  rather than raised, so a cache miss during an outage can answer with a
  retryable 503 instead of an auth failure.
  """

  import Ecto.Query

  require Logger

  alias Smolsqls.ControlPlane.{Database, DatabaseToken, Tenant, TenantApiKey}
  alias Smolsqls.ReadModel.CachedRow
  alias Smolsqls.Repo

  @type result :: {:ok, struct()} | {:error, :not_found} | {:error, :metadb_unavailable}

  @spec fetch(Smolsqls.ReadModel.table(), String.t()) :: result()
  def fetch(table, key) do
    if valid_key?(table, key), do: do_fetch(table, key), else: {:error, :not_found}
  end

  @doc """
  Whether a key can address a row at all. A malformed id is answered
  without touching Postgres, and — just as important — without the cache
  storing a negative entry for garbage a client made up.
  """
  @spec valid_key?(Smolsqls.ReadModel.table(), term()) :: boolean()
  def valid_key?(table, key) when table in [:database_tokens, :tenant_api_keys],
    do: is_binary(key)

  def valid_key?(_table, key), do: is_binary(key) and match?({:ok, _}, Ecto.UUID.cast(key))

  @doc """
  Runs a metadb read, reporting an unreachable metadb as
  `{:error, :metadb_unavailable}` instead of raising.
  """
  @spec guard((-> result)) :: result | {:error, :metadb_unavailable} when result: term()
  def guard(fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("metadb unavailable: #{Exception.message(error)}")
      {:error, :metadb_unavailable}
  catch
    :exit, reason ->
      Logger.warning("metadb unavailable: #{inspect(reason)}")
      {:error, :metadb_unavailable}
  end

  defp do_fetch(:databases, id), do: one_by(Database, :databases, :id, id)
  defp do_fetch(:tenants, id), do: one_by(Tenant, :tenants, :id, id)

  defp do_fetch(:database_tokens, token_hash) do
    one_by(DatabaseToken, :database_tokens, :token_hash, token_hash)
  end

  defp do_fetch(:tenant_api_keys, token_hash) do
    one_by(TenantApiKey, :tenant_api_keys, :token_hash, token_hash)
  end

  defp one_by(schema, table, key_field, key) do
    fields = CachedRow.fields(schema, table)

    from(row in schema,
      where: field(row, ^key_field) == ^key,
      select: struct(row, ^fields)
    )
    |> one()
  end

  @doc """
  Cheap reachability check for the sweeper: expiry pauses while the
  metadb is unreachable, and a quiet node makes no other reads to learn
  that from.
  """
  @spec ping() :: :ok | {:error, :metadb_unavailable}
  def ping do
    case one(from(t in Tenant, select: struct(t, [:id]), limit: 1)) do
      {:error, :metadb_unavailable} = error -> error
      _found_or_empty -> :ok
    end
  end

  defp one(query) do
    guard(fn ->
      case Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end
end
