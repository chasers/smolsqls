defmodule Sqlites.ReadModelTest do
  use ExUnit.Case, async: false

  alias Sqlites.ControlPlane.{Database, DatabaseToken, Tenant, TenantApiKey}
  alias Sqlites.ReadModel

  setup do
    start_supervised!({ReadModel, snapshot: false})
    :ok
  end

  defp database(overrides \\ %{}) do
    struct!(
      %Database{
        id: Ecto.UUID.generate(),
        tenant_id: Ecto.UUID.generate(),
        name: "db",
        status: :active
      },
      overrides
    )
  end

  defp database_token(database, overrides \\ %{}) do
    struct!(
      %DatabaseToken{
        id: Ecto.UUID.generate(),
        database_id: database.id,
        token_hash: Sqlites.Secrets.hash("token-#{System.unique_integer([:positive])}"),
        enabled: true
      },
      overrides
    )
  end

  test "stores and looks up databases by id" do
    db = database()
    assert :ok = ReadModel.put_database(db)

    assert %Database{id: id} = ReadModel.get_database(db.id)
    assert id == db.id

    assert ReadModel.get_database("missing") == nil

    ReadModel.delete_database(db.id)
    assert ReadModel.get_database(db.id) == nil
  end

  test "database tokens index by hash and follow updates and deletes" do
    db = database()
    ReadModel.put_database(db)

    token = database_token(db)
    assert :ok = ReadModel.put_database_token(token)

    found = ReadModel.get_database_token_by_hash(token.token_hash)
    assert found.id == token.id
    assert found.database_id == db.id

    disabled = %{token | enabled: false}
    ReadModel.put_database_token(disabled)
    refute ReadModel.get_database_token_by_hash(token.token_hash).enabled

    ReadModel.delete_database_token(token.id)
    assert ReadModel.get_database_token_by_hash(token.token_hash) == nil
  end

  test "a database can hold several usable tokens at once" do
    db = database()
    first = database_token(db)
    second = database_token(db)

    ReadModel.put_database_token(first)
    ReadModel.put_database_token(second)

    assert ReadModel.get_database_token_by_hash(first.token_hash).id == first.id
    assert ReadModel.get_database_token_by_hash(second.token_hash).id == second.id
  end

  test "tenant api keys mirror the same shape" do
    tenant = %Tenant{id: Ecto.UUID.generate(), name: "T", slug: "t"}
    ReadModel.put_tenant(tenant)

    key_hash = Sqlites.Secrets.hash("sk_x")

    key = %TenantApiKey{
      id: Ecto.UUID.generate(),
      tenant_id: tenant.id,
      token_hash: key_hash,
      enabled: true
    }

    ReadModel.put_tenant_api_key(key)

    assert ReadModel.get_tenant_api_key_by_hash(key_hash).tenant_id == tenant.id

    ReadModel.delete_tenant_api_key(key.id)
    assert ReadModel.get_tenant_api_key_by_hash(key_hash) == nil

    ReadModel.delete_tenant(tenant.id)
    assert ReadModel.get_tenant(tenant.id) == nil
  end

  test "truncate clears token tables and their hash indexes" do
    db = database()
    token = database_token(db)
    ReadModel.put_database(db)
    ReadModel.put_database_token(token)

    ReadModel.truncate(:database_tokens)
    assert ReadModel.get_database_token_by_hash(token.token_hash) == nil

    ReadModel.truncate(:databases)
    assert ReadModel.get_database(db.id) == nil
  end
end
