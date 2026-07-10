defmodule Smolsqls.ControlPlane do
  @moduledoc """
  Tenant-facing metadata: tenants and the databases they own. This context
  never touches a SQLite file directly — placement and file lifecycle are
  carried out by `Smolsqls.DataPlane` and, in a deployed cluster, by the
  Kubernetes operator.

  Request-path reads (`authenticate_tenant/1`, `authenticate_database/2`,
  `authenticate_database_by_token/1`, `lookup_database/1`) are served
  from `Smolsqls.ReadModel` when it is ready, so Postgres never sits on
  the data path. Writes go to Postgres (the source of truth) and are
  also applied to the local read model immediately; other nodes
  converge via the WAL feed.

  Credentials are managed rows, not columns: `database_tokens` and
  `tenant_api_keys` hold any number of permanent secrets per owner,
  each independently disableable, expirable, and deletable. Creating a
  tenant or database creates a `"default"` secret alongside it,
  surfaced once on the returned struct's virtual `api_key`/`auth_token`
  field.
  """

  import Ecto.Query

  alias Smolsqls.ControlPlane.{Database, DatabaseToken, Tenant, TenantApiKey}
  alias Smolsqls.ControlPlane.Node, as: NodeRow
  alias Smolsqls.ReadModel
  alias Smolsqls.Repo

  @doc """
  Creates a tenant with a `"default"` API key. When `opts[:signup_ip]`
  is given, the creation is rate-limited per IP (see
  `Smolsqls.SignupLimiter` and `config :smolsqls, :signup_rate_limit`);
  without it (internal tooling, tests) no limit applies.
  """
  @spec create_tenant(map(), keyword()) ::
          {:ok, Tenant.t()} | {:error, :signup_rate_limited | Ecto.Changeset.t()}
  def create_tenant(attrs, opts \\ []) do
    signup_ip = Keyword.get(opts, :signup_ip)

    with :ok <- check_signup_limit(signup_ip) do
      Repo.transaction(fn ->
        with {:ok, tenant} <- Repo.insert(Tenant.changeset(%Tenant{}, attrs)),
             {:ok, api_key} <-
               Repo.insert(
                 TenantApiKey.create_changeset(
                   %TenantApiKey{tenant_id: tenant.id},
                   %{"name" => "default"}
                 )
               ) do
          {tenant, api_key}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, {tenant, api_key}} ->
          record_signup(signup_ip)
          write_through({:ok, tenant}, &ReadModel.put_tenant/1)
          write_through({:ok, api_key}, &ReadModel.put_tenant_api_key/1)
          {:ok, %{tenant | api_key: api_key.token}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp check_signup_limit(nil), do: :ok
  defp check_signup_limit(ip), do: Smolsqls.SignupLimiter.check(ip)

  defp record_signup(nil), do: :ok
  defp record_signup(ip), do: Smolsqls.SignupLimiter.record(ip)

  def get_tenant(id), do: Repo.get(Tenant, id)

  @doc """
  Hot-path tenant lookup, served from the read model when ready.
  """
  @spec lookup_tenant(String.t()) :: Tenant.t() | nil
  def lookup_tenant(id) when is_binary(id) do
    if ReadModel.ready?() do
      ReadModel.get_tenant(id)
    else
      get_tenant(id)
    end
  end

  def get_tenant_by_slug(slug), do: Repo.get_by(Tenant, slug: slug)

  def authenticate_tenant(api_key) when is_binary(api_key) do
    hash = Smolsqls.Secrets.hash(api_key)

    lookup =
      if ReadModel.ready?() do
        ReadModel.get_tenant_api_key_by_hash(hash)
      else
        Repo.get_by(TenantApiKey, token_hash: hash)
      end

    with %TenantApiKey{} = key <- lookup,
         true <- token_usable?(key),
         %Tenant{} = tenant <- lookup_tenant(key.tenant_id) do
      {:ok, tenant}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Decrypts a credential's secret for an explicit reveal request,
  returned on the virtual `token` field. Fails only when the
  encryption key changed since the secret was created.
  """
  @spec reveal(DatabaseToken.t() | TenantApiKey.t()) ::
          {:ok, DatabaseToken.t() | TenantApiKey.t()} | :error
  def reveal(%{token_ciphertext: ciphertext} = credential) do
    with {:ok, secret} <- Smolsqls.Secrets.decrypt(ciphertext) do
      {:ok, %{credential | token: secret}}
    end
  end

  @doc """
  Whether a `DatabaseToken` or `TenantApiKey` currently authenticates:
  enabled and not expired.
  """
  @spec token_usable?(DatabaseToken.t() | TenantApiKey.t()) :: boolean()
  def token_usable?(%{enabled: enabled, expires_at: expires_at}) do
    enabled and (is_nil(expires_at) or DateTime.after?(expires_at, DateTime.utc_now()))
  end

  @spec list_tenant_api_keys(Tenant.t()) :: [TenantApiKey.t()]
  def list_tenant_api_keys(%Tenant{id: tenant_id}) do
    TenantApiKey
    |> where([k], k.tenant_id == ^tenant_id)
    |> order_by([k], asc: k.inserted_at)
    |> Repo.all()
  end

  @spec get_tenant_api_key(Tenant.t(), String.t()) :: TenantApiKey.t() | nil
  def get_tenant_api_key(%Tenant{id: tenant_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.one(where(TenantApiKey, [k], k.tenant_id == ^tenant_id and k.id == ^uuid))

      :error ->
        nil
    end
  end

  @spec create_tenant_api_key(Tenant.t(), map()) ::
          {:ok, TenantApiKey.t()} | {:error, Ecto.Changeset.t()}
  def create_tenant_api_key(%Tenant{} = tenant, attrs) do
    %TenantApiKey{tenant_id: tenant.id}
    |> TenantApiKey.create_changeset(attrs)
    |> Repo.insert()
    |> write_through(&ReadModel.put_tenant_api_key/1)
  end

  @spec update_tenant_api_key(TenantApiKey.t(), map()) ::
          {:ok, TenantApiKey.t()} | {:error, :last_api_key | Ecto.Changeset.t()}
  def update_tenant_api_key(%TenantApiKey{} = key, attrs) do
    disabling? = Map.get(attrs, "enabled") in [false, "false"]

    if disabling? and last_usable_api_key?(key) do
      {:error, :last_api_key}
    else
      key
      |> TenantApiKey.update_changeset(attrs)
      |> Repo.update()
      |> write_through(&ReadModel.put_tenant_api_key/1)
    end
  end

  @spec delete_tenant_api_key(TenantApiKey.t()) ::
          {:ok, TenantApiKey.t()} | {:error, :last_api_key | Ecto.Changeset.t()}
  def delete_tenant_api_key(%TenantApiKey{} = key) do
    if last_usable_api_key?(key) do
      {:error, :last_api_key}
    else
      key
      |> Repo.delete()
      |> write_through(&ReadModel.delete_tenant_api_key(&1.id))
    end
  end

  defp last_usable_api_key?(%TenantApiKey{} = key) do
    token_usable?(key) and
      TenantApiKey
      |> where([k], k.tenant_id == ^key.tenant_id and k.id != ^key.id and k.enabled == true)
      |> where([k], is_nil(k.expires_at) or k.expires_at > ^DateTime.utc_now())
      |> Repo.aggregate(:count) == 0
  end

  def update_tenant(%Tenant{} = tenant, attrs) do
    tenant
    |> Tenant.update_changeset(attrs)
    |> Repo.update()
    |> write_through(&ReadModel.put_tenant/1)
  end

  def delete_tenant(%Tenant{} = tenant) do
    tenant
    |> Repo.delete()
    |> write_through(&ReadModel.delete_tenant(&1.id))
  end

  def list_databases(%Tenant{id: tenant_id}) do
    Database
    |> where([d], d.tenant_id == ^tenant_id)
    |> order_by([d], asc: d.inserted_at)
    |> Repo.all()
  end

  @doc """
  Whether any database was branched from this one (has it as its
  `source_database_id`). Deleting a database with branches is blocked.
  """
  @spec has_branches?(Database.t()) :: boolean()
  def has_branches?(%Database{id: id}) do
    Database
    |> where([d], d.source_database_id == ^id)
    |> Repo.exists?()
  end

  @doc """
  Count of databases branched directly from this one.
  """
  @spec branch_count(Database.t()) :: non_neg_integer()
  def branch_count(%Database{id: id}) do
    Database
    |> where([d], d.source_database_id == ^id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Branch counts for a tenant's databases as a `%{source_database_id => count}`
  map — one query for the whole list, powering the dashboard's branch badge.
  """
  @spec branch_counts(Tenant.t()) :: %{optional(String.t()) => non_neg_integer()}
  def branch_counts(%Tenant{id: tenant_id}) do
    Database
    |> where([d], d.tenant_id == ^tenant_id and not is_nil(d.source_database_id))
    |> group_by([d], d.source_database_id)
    |> select([d], {d.source_database_id, count(d.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Ephemeral databases whose `expires_at` has passed — the expiry sweep's
  work list, soonest-expired first. `:limit` bounds the batch.
  """
  @spec due_for_expiry(DateTime.t(), keyword()) :: [Database.t()]
  def due_for_expiry(now, opts \\ []) do
    query =
      Database
      |> where([d], not is_nil(d.expires_at) and d.expires_at <= ^now)
      |> order_by([d], asc: d.expires_at)

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> limit(query, ^limit)
      end

    Repo.all(query)
  end

  @doc """
  Cursor-paginated database listing: keyset on `(inserted_at, id)`,
  `after` is the id of the last row of the previous page. Returns
  `%{entries: [...], next: id | nil}`.
  """
  @spec paginate_databases(Tenant.t(), keyword()) ::
          {:ok, %{entries: [Database.t()], next: String.t() | nil}} | {:error, :invalid_cursor}
  def paginate_databases(%Tenant{id: tenant_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    with {:ok, cursor} <- database_cursor(tenant_id, Keyword.get(opts, :after)) do
      entries =
        Database
        |> where([d], d.tenant_id == ^tenant_id)
        |> after_database_cursor(cursor)
        |> order_by([d], asc: d.inserted_at, asc: d.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      {page, rest} = Enum.split(entries, limit)
      {:ok, %{entries: page, next: if(rest == [], do: nil, else: List.last(page).id)}}
    end
  end

  defp database_cursor(_tenant_id, nil), do: {:ok, nil}

  defp database_cursor(tenant_id, after_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(after_id),
         %Database{} = cursor <-
           Repo.one(where(Database, [d], d.tenant_id == ^tenant_id and d.id == ^uuid)) do
      {:ok, cursor}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp after_database_cursor(query, nil), do: query

  defp after_database_cursor(query, %Database{inserted_at: inserted_at, id: id}) do
    where(
      query,
      [d],
      d.inserted_at > ^inserted_at or (d.inserted_at == ^inserted_at and d.id > ^id)
    )
  end

  def get_database(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Database, uuid)
      :error -> nil
    end
  end

  def get_database(%Tenant{id: tenant_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Database
        |> where([d], d.tenant_id == ^tenant_id and d.id == ^uuid)
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  Hot-path database lookup, served from the read model when ready.
  """
  @spec lookup_database(String.t()) :: Database.t() | nil
  def lookup_database(id) when is_binary(id) do
    if ReadModel.ready?() do
      ReadModel.get_database(id)
    else
      get_database(id)
    end
  end

  def authenticate_database(id, auth_token)
      when is_binary(id) and is_binary(auth_token) do
    with %DatabaseToken{} = token <- database_token_by_secret(auth_token),
         true <- token.database_id == id and token_usable?(token),
         %Database{} = database <- lookup_database(id) do
      {:ok, database}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Token-only authentication (the Hrana path): resolves the database
  through any of its usable tokens.
  """
  @spec authenticate_database_by_token(String.t()) ::
          {:ok, Database.t()} | {:error, :unauthorized}
  def authenticate_database_by_token(auth_token) when is_binary(auth_token) do
    with %DatabaseToken{} = token <- database_token_by_secret(auth_token),
         true <- token_usable?(token),
         %Database{} = database <- lookup_database(token.database_id) do
      {:ok, database}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp database_token_by_secret(secret) do
    hash = Smolsqls.Secrets.hash(secret)

    if ReadModel.ready?() do
      ReadModel.get_database_token_by_hash(hash)
    else
      Repo.get_by(DatabaseToken, token_hash: hash)
    end
  end

  @spec list_database_tokens(Database.t()) :: [DatabaseToken.t()]
  def list_database_tokens(%Database{id: database_id}) do
    DatabaseToken
    |> where([t], t.database_id == ^database_id)
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  @spec get_database_token(Database.t(), String.t()) :: DatabaseToken.t() | nil
  def get_database_token(%Database{id: database_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.one(where(DatabaseToken, [t], t.database_id == ^database_id and t.id == ^uuid))

      :error ->
        nil
    end
  end

  @spec create_database_token(Database.t(), map()) ::
          {:ok, DatabaseToken.t()} | {:error, Ecto.Changeset.t()}
  def create_database_token(%Database{} = database, attrs) do
    %DatabaseToken{database_id: database.id}
    |> DatabaseToken.create_changeset(attrs)
    |> Repo.insert()
    |> write_through(&ReadModel.put_database_token/1)
  end

  @spec update_database_token(DatabaseToken.t(), map()) ::
          {:ok, DatabaseToken.t()} | {:error, Ecto.Changeset.t()}
  def update_database_token(%DatabaseToken{} = token, attrs) do
    token
    |> DatabaseToken.update_changeset(attrs)
    |> Repo.update()
    |> write_through(&ReadModel.put_database_token/1)
  end

  @spec delete_database_token(DatabaseToken.t()) ::
          {:ok, DatabaseToken.t()} | {:error, Ecto.Changeset.t()}
  def delete_database_token(%DatabaseToken{} = token) do
    token
    |> Repo.delete()
    |> write_through(&ReadModel.delete_database_token(&1.id))
  end

  def create_database(%Tenant{} = tenant, attrs) do
    max_databases = Smolsqls.Limits.max_databases(tenant)

    if is_integer(max_databases) and database_count(tenant) >= max_databases do
      {:error, :database_limit_reached}
    else
      insert_database_with_default_token(tenant, attrs)
    end
  end

  defp insert_database_with_default_token(tenant, attrs) do
    Repo.transaction(fn ->
      with {:ok, database} <-
             Repo.insert(
               Database.create_changeset(%Database{}, Map.put(attrs, "tenant_id", tenant.id))
             ),
           {:ok, token} <-
             Repo.insert(
               DatabaseToken.create_changeset(
                 %DatabaseToken{database_id: database.id},
                 %{"name" => "default"}
               )
             ) do
        {database, token}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {database, token}} ->
        write_through({:ok, database}, &ReadModel.put_database/1)
        write_through({:ok, token}, &ReadModel.put_database_token/1)
        {:ok, %{database | auth_token: token.token}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp database_count(%Tenant{id: tenant_id}) do
    Database
    |> where([d], d.tenant_id == ^tenant_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Creates a child database row (a branch of `source`) with its own default
  token, in the source's tenant. Lineage (`source_database_id`,
  `branch_point_at`) is stamped from `attrs`, defaulting the source and the
  current time. The child starts at snapshot generation 1, matching the
  seeded artifact the data plane places at its idle-snapshot key. Counts
  against the tenant database limit like any other database (a branch is a
  database).
  """
  @spec branch_database(Database.t(), map()) :: {:ok, Database.t()} | {:error, term()}
  def branch_database(%Database{} = source, attrs) do
    tenant = get_tenant(source.tenant_id)
    max_databases = tenant && Smolsqls.Limits.max_databases(tenant)

    if is_integer(max_databases) and database_count(tenant) >= max_databases do
      {:error, :database_limit_reached}
    else
      insert_branch_with_default_token(source, attrs)
    end
  end

  defp insert_branch_with_default_token(%Database{} = source, attrs) do
    attrs =
      attrs
      |> Map.put("tenant_id", source.tenant_id)
      |> Map.put_new("source_database_id", source.id)
      |> Map.put_new("branch_point_at", DateTime.utc_now())
      |> put_source_region(source)

    Repo.transaction(fn ->
      with {:ok, database} <-
             Repo.insert(
               %Database{}
               |> Database.branch_changeset(attrs)
               |> Ecto.Changeset.put_change(:snapshot_generation, 1)
             ),
           {:ok, token} <-
             Repo.insert(
               DatabaseToken.create_changeset(
                 %DatabaseToken{database_id: database.id},
                 %{"name" => "default"}
               )
             ) do
        {database, token}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {database, token}} ->
        write_through({:ok, database}, &ReadModel.put_database/1)
        write_through({:ok, token}, &ReadModel.put_database_token/1)
        {:ok, %{database | auth_token: token.token}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp put_source_region(attrs, %Database{region: nil}), do: attrs

  defp put_source_region(attrs, %Database{region: region}),
    do: Map.put_new(attrs, "region", region)

  def update_database_settings(%Database{} = database, attrs) do
    database
    |> Database.settings_changeset(attrs)
    |> Repo.update()
    |> write_through(&ReadModel.put_database/1)
  end

  def mark_placed(%Database{} = database, node, file_path) do
    database
    |> Database.placement_changeset(%{
      status: :active,
      node: to_string(node),
      file_path: file_path
    })
    |> Repo.update()
    |> write_through(&ReadModel.put_database/1)
  end

  @doc """
  Upserts a node's cluster identity and region into the `nodes` table.
  Idempotent per `node_name`; called on boot by `Smolsqls.NodeRegistry`.
  """
  @spec upsert_node(String.t(), String.t()) :: {:ok, NodeRow.t()} | {:error, Ecto.Changeset.t()}
  def upsert_node(node_name, region) do
    now = DateTime.utc_now()
    cloud = Smolsqls.Regions.cloud(region)

    %NodeRow{}
    |> NodeRow.changeset(%{
      node_name: node_name,
      region: region,
      cloud: cloud,
      status: "up",
      last_seen_at: now
    })
    |> Repo.insert(
      on_conflict: [
        set: [region: region, cloud: cloud, status: "up", last_seen_at: now, updated_at: now]
      ],
      conflict_target: :node_name
    )
  end

  @doc """
  Refreshes a node's `last_seen_at` heartbeat. No-op if the row is absent.
  """
  @spec heartbeat_node(String.t()) :: :ok
  def heartbeat_node(node_name) do
    now = DateTime.utc_now()

    NodeRow
    |> where([n], n.node_name == ^node_name)
    |> Repo.update_all(set: [last_seen_at: now, status: "up", updated_at: now])

    :ok
  end

  @doc """
  The node names recorded in a given region. Region-aware placement
  intersects these with the live cluster to pick an owner.
  """
  @spec nodes_in_region(String.t()) :: [String.t()]
  def nodes_in_region(region) do
    NodeRow
    |> where([n], n.region == ^region)
    |> select([n], n.node_name)
    |> Repo.all()
  end

  @doc """
  Records that a fresh idle snapshot of the database was shipped to the
  object store: bumps `snapshot_generation` atomically and stamps
  `last_snapshot_at`. Returns the updated row so the caller can record
  the shipped generation locally.
  """
  @spec record_idle_snapshot(Database.t()) :: {:ok, Database.t()} | {:error, term()}
  def record_idle_snapshot(%Database{id: id}) do
    now = DateTime.utc_now()

    Database
    |> where([d], d.id == ^id)
    |> select([d], d)
    |> Repo.update_all(
      inc: [snapshot_generation: 1],
      set: [last_snapshot_at: now, updated_at: now]
    )
    |> case do
      {1, [database]} -> write_through({:ok, database}, &ReadModel.put_database/1)
      {0, _} -> {:error, :not_found}
    end
  end

  def mark_deleting(%Database{} = database) do
    database
    |> Database.placement_changeset(%{status: :deleting})
    |> Repo.update()
    |> write_through(&ReadModel.put_database/1)
  end

  def delete_database(%Database{} = database) do
    database
    |> Repo.delete()
    |> write_through(&ReadModel.delete_database(&1.id))
  end

  defp write_through({:ok, record} = result, apply_fun) do
    if ReadModel.ready?(), do: apply_fun.(record)
    result
  end

  defp write_through(result, _apply_fun), do: result
end
