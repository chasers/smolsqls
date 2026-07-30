defmodule Smolsqls.ReadModel.CachedRowTest do
  @moduledoc """
  The cache is populated by three independent paths — a Postgres read on a
  miss (`Source`), the WAL feed (`Row`), and local write-through — and all
  three must produce the same shape. If one stops populating a field, that
  field silently becomes `nil` depending on how a row happened to get
  cached, which is the hardest class of bug to see in production.

  Every nullable column is filled before comparing. A row with `nil`s in it
  cannot detect a dropped column, because "not populated" and "populated
  with nothing" look identical.
  """

  use Smolsqls.DataCase

  import Smolsqls.Fixtures

  alias Smolsqls.ControlPlane.{Database, DatabaseToken, Tenant, TenantApiKey}
  alias Smolsqls.ReadModel.{CachedRow, Row, Source}

  test "a cached database matches a Postgres row on every field" do
    tenant = tenant_fixture()
    source = database_fixture(tenant, %{"name" => "source-db"})
    database = placed_database_fixture(tenant)
    stored = fill_database(database, source)

    assert {:ok, loaded} = Source.fetch(:databases, database.id)
    built = Row.build_database(feed_values(stored))

    assert_same_shape(loaded, built, :databases, Database)
    assert loaded.name == stored.name
    assert built.name == stored.name
    assert DateTime.compare(built.inserted_at, stored.inserted_at) == :eq
  end

  test "a cached tenant matches a Postgres row on every field" do
    tenant = tenant_fixture()
    stored = Repo.get!(Tenant, tenant.id)

    assert {:ok, loaded} = Source.fetch(:tenants, tenant.id)
    built = Row.build_tenant(feed_values(stored))

    assert_same_shape(loaded, built, :tenants, Tenant)
    assert built.slug == stored.slug
  end

  test "a cached database token carries every field but the ciphertext" do
    tenant = tenant_fixture()
    database = database_fixture(tenant)
    hash = Smolsqls.Secrets.hash(database.auth_token)
    stored = fill_expiry(Repo.get_by!(DatabaseToken, token_hash: hash))

    assert {:ok, loaded} = Source.fetch(:database_tokens, hash)
    built = Row.build_database_token(feed_values(stored))

    assert_same_shape(loaded, built, :database_tokens, DatabaseToken)
    assert is_nil(loaded.token_ciphertext)
    assert is_nil(built.token_ciphertext)
    refute is_nil(stored.token_ciphertext)
  end

  test "a cached tenant api key carries every field but the ciphertext" do
    tenant = tenant_fixture()
    hash = Smolsqls.Secrets.hash(tenant.api_key)
    stored = fill_expiry(Repo.get_by!(TenantApiKey, token_hash: hash))

    assert {:ok, loaded} = Source.fetch(:tenant_api_keys, hash)
    built = Row.build_tenant_api_key(feed_values(stored))

    assert_same_shape(loaded, built, :tenant_api_keys, TenantApiKey)
    assert is_nil(loaded.token_ciphertext)
    assert is_nil(built.token_ciphertext)
  end

  test "write-through clears the ciphertext and keeps everything else" do
    tenant = tenant_fixture()
    hash = Smolsqls.Secrets.hash(tenant.api_key)
    stored = Repo.get_by!(TenantApiKey, token_hash: hash)

    narrowed = CachedRow.narrow(:tenant_api_keys, stored)

    assert is_nil(narrowed.token_ciphertext)
    assert narrowed.token_hash == stored.token_hash
    assert narrowed.name == stored.name
    assert narrowed.inserted_at == stored.inserted_at
    assert CachedRow.narrow(:databases, stored) == stored
  end

  test "write-through clears the virtual plaintext token the create path carries" do
    tenant = tenant_fixture()
    hash = Smolsqls.Secrets.hash(tenant.api_key)
    created = %{Repo.get_by!(TenantApiKey, token_hash: hash) | token: tenant.api_key}

    assert is_nil(CachedRow.narrow(:tenant_api_keys, created).token)

    database = database_fixture(tenant)
    db_hash = Smolsqls.Secrets.hash(database.auth_token)

    created_token = %{
      Repo.get_by!(DatabaseToken, token_hash: db_hash)
      | token: database.auth_token
    }

    assert is_nil(CachedRow.narrow(:database_tokens, created_token).token)
  end

  defp fill_database(database, source) do
    now = DateTime.utc_now()

    database
    |> Ecto.Changeset.change(%{
      region: "gcp-us-central1",
      cloud: "gcp",
      last_snapshot_at: now,
      source_database_id: source.id,
      branch_point_at: now,
      expires_at: DateTime.add(now, 3600, :second),
      limits: %{"max_size_bytes" => 500}
    })
    |> Repo.update!()
    |> assert_no_nils()
  end

  defp fill_expiry(token) do
    token
    |> Ecto.Changeset.change(%{expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)})
    |> Repo.update!()
    |> assert_no_nils()
  end

  defp assert_no_nils(%schema{} = row) do
    cached = CachedRow.fields(schema, cache_table(schema))
    unset = Enum.filter(cached, fn field -> is_nil(Map.fetch!(row, field)) end)

    assert unset == [],
           "these cached columns are nil, so drift in them cannot be detected: #{inspect(unset)}"

    row
  end

  defp cache_table(Database), do: :databases
  defp cache_table(Tenant), do: :tenants
  defp cache_table(DatabaseToken), do: :database_tokens
  defp cache_table(TenantApiKey), do: :tenant_api_keys

  defp assert_same_shape(from_postgres, from_feed, table, schema) do
    redacted = MapSet.new(CachedRow.redacted(table))
    expected = MapSet.new(CachedRow.fields(schema, table))

    for {label, row} <- [postgres: from_postgres, feed: from_feed] do
      assert MapSet.disjoint?(populated(row), redacted),
             "the #{label} path cached a redacted field: " <>
               inspect(MapSet.intersection(populated(row), redacted))

      assert MapSet.subset?(populated(row), expected),
             "the #{label} path populated a field the cache does not keep: " <>
               inspect(MapSet.difference(populated(row), expected))
    end

    assert populated(from_postgres) == populated(from_feed),
           "the two paths disagree on which fields a cached row carries: " <>
             inspect(symmetric_difference(populated(from_postgres), populated(from_feed)))
  end

  defp symmetric_difference(left, right) do
    MapSet.union(MapSet.difference(left, right), MapSet.difference(right, left))
  end

  defp populated(%schema{} = row) do
    schema.__schema__(:fields)
    |> Enum.reject(fn field -> is_nil(Map.fetch!(row, field)) end)
    |> MapSet.new()
  end

  defp feed_values(%schema{} = row) do
    schema.__schema__(:fields)
    |> Map.new(fn field -> {to_string(field), encode(Map.fetch!(row, field))} end)
  end

  defp encode(nil), do: nil
  defp encode(true), do: "t"
  defp encode(false), do: "f"
  defp encode(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode(value) when is_map(value), do: Jason.encode!(value)
  defp encode(value) when is_atom(value), do: Atom.to_string(value)
  defp encode(value) when is_integer(value), do: Integer.to_string(value)
  defp encode(value) when is_binary(value), do: value
end
