defmodule Smolsqls.ReadModel do
  @moduledoc """
  Full in-memory replica of the request-path metadb tables (`tenants`,
  `databases`, `database_tokens`, `tenant_api_keys`), so auth and
  placement reads never touch Postgres. Postgres remains the sole
  source of truth for writes; these tables are written only by the
  COPY snapshot, the WAL replication feed, and local write-through
  from control-plane mutations.

  When the read model is ready, a miss here definitively means the row
  does not exist. Rows carry the same fields as their Repo structs,
  timestamps included, so a read-model struct is interchangeable with
  one loaded from Postgres.
  """

  use GenServer

  alias Smolsqls.ControlPlane.{Database, DatabaseToken, Tenant, TenantApiKey}

  @databases __MODULE__.Databases
  @database_tokens __MODULE__.DatabaseTokens
  @database_tokens_by_hash __MODULE__.DatabaseTokensByHash
  @tenants __MODULE__.Tenants
  @tenant_api_keys __MODULE__.TenantApiKeys
  @tenant_api_keys_by_hash __MODULE__.TenantApiKeysByHash

  @tables [
    @databases,
    @database_tokens,
    @database_tokens_by_hash,
    @tenants,
    @tenant_api_keys,
    @tenant_api_keys_by_hash
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, timeout: :timer.minutes(5))
  end

  @impl true
  def init(opts) do
    for table <- @tables do
      :ets.new(table, [:set, :named_table, :public, read_concurrency: true])
    end

    if Keyword.get(opts, :snapshot, true) do
      Smolsqls.ReadModel.Snapshot.load()
      mark_ready()
    end

    {:ok, %{}}
  end

  @spec ready?() :: boolean()
  def ready? do
    :persistent_term.get({__MODULE__, :ready}, false)
  end

  def mark_ready do
    :persistent_term.put({__MODULE__, :ready}, true)
  end

  def mark_not_ready do
    :persistent_term.erase({__MODULE__, :ready})
    :ok
  end

  @spec get_database(String.t()) :: Database.t() | nil
  def get_database(id) do
    case :ets.lookup(@databases, id) do
      [{^id, database}] -> database
      [] -> nil
    end
  end

  @spec get_tenant(String.t()) :: Tenant.t() | nil
  def get_tenant(id) do
    case :ets.lookup(@tenants, id) do
      [{^id, tenant}] -> tenant
      [] -> nil
    end
  end

  @spec get_database_token_by_hash(String.t()) :: DatabaseToken.t() | nil
  def get_database_token_by_hash(token_hash) do
    lookup_by_hash(@database_tokens_by_hash, @database_tokens, token_hash)
  end

  @spec get_tenant_api_key_by_hash(String.t()) :: TenantApiKey.t() | nil
  def get_tenant_api_key_by_hash(token_hash) do
    lookup_by_hash(@tenant_api_keys_by_hash, @tenant_api_keys, token_hash)
  end

  defp lookup_by_hash(hash_table, table, token_hash) do
    with [{^token_hash, id}] <- :ets.lookup(hash_table, token_hash),
         [{^id, row}] <- :ets.lookup(table, id) do
      row
    else
      _ -> nil
    end
  end

  @spec put_database(Database.t()) :: :ok
  def put_database(%Database{} = database) do
    :ets.insert(@databases, {database.id, database})
    :ok
  end

  @spec delete_database(String.t()) :: :ok
  def delete_database(id) do
    :ets.delete(@databases, id)
    :ok
  end

  @spec put_tenant(Tenant.t()) :: :ok
  def put_tenant(%Tenant{} = tenant) do
    :ets.insert(@tenants, {tenant.id, tenant})
    :ok
  end

  @spec delete_tenant(String.t()) :: :ok
  def delete_tenant(id) do
    :ets.delete(@tenants, id)
    :ok
  end

  @spec put_database_token(DatabaseToken.t()) :: :ok
  def put_database_token(%DatabaseToken{} = token) do
    put_hashed_row(@database_tokens, @database_tokens_by_hash, token.id, token.token_hash, token)
  end

  @spec delete_database_token(String.t()) :: :ok
  def delete_database_token(id) do
    delete_hashed_row(@database_tokens, @database_tokens_by_hash, id)
  end

  @spec put_tenant_api_key(TenantApiKey.t()) :: :ok
  def put_tenant_api_key(%TenantApiKey{} = key) do
    put_hashed_row(@tenant_api_keys, @tenant_api_keys_by_hash, key.id, key.token_hash, key)
  end

  @spec delete_tenant_api_key(String.t()) :: :ok
  def delete_tenant_api_key(id) do
    delete_hashed_row(@tenant_api_keys, @tenant_api_keys_by_hash, id)
  end

  defp put_hashed_row(table, hash_table, id, token_hash, row) do
    case :ets.lookup(table, id) do
      [{^id, %{token_hash: old_hash}}] when old_hash != token_hash ->
        :ets.delete(hash_table, old_hash)

      _ ->
        :ok
    end

    :ets.insert(table, {id, row})
    :ets.insert(hash_table, {token_hash, id})
    :ok
  end

  defp delete_hashed_row(table, hash_table, id) do
    case :ets.lookup(table, id) do
      [{^id, %{token_hash: token_hash}}] -> :ets.delete(hash_table, token_hash)
      [] -> :ok
    end

    :ets.delete(table, id)
    :ok
  end

  @spec truncate(:databases | :database_tokens | :tenants | :tenant_api_keys) :: :ok
  def truncate(:databases) do
    :ets.delete_all_objects(@databases)
    :ok
  end

  def truncate(:tenants) do
    :ets.delete_all_objects(@tenants)
    :ok
  end

  def truncate(:database_tokens) do
    :ets.delete_all_objects(@database_tokens)
    :ets.delete_all_objects(@database_tokens_by_hash)
    :ok
  end

  def truncate(:tenant_api_keys) do
    :ets.delete_all_objects(@tenant_api_keys)
    :ets.delete_all_objects(@tenant_api_keys_by_hash)
    :ok
  end
end
