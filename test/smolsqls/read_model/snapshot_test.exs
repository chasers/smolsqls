defmodule Smolsqls.ReadModel.SnapshotTest do
  use Smolsqls.DataCase

  import Smolsqls.Fixtures

  alias Smolsqls.ReadModel
  alias Smolsqls.ReadModel.Snapshot

  setup do
    start_supervised!({ReadModel, snapshot: false})
    :ok
  end

  test "loads tenants, databases, and their secrets into the read model via COPY" do
    tenant = tenant_fixture()
    database = database_fixture(tenant)
    placed = placed_database_fixture(tenant)

    assert :ok = Snapshot.load()

    loaded_key = ReadModel.get_tenant_api_key_by_hash(Smolsqls.Secrets.hash(tenant.api_key))
    assert loaded_key.tenant_id == tenant.id
    assert ReadModel.get_tenant(tenant.id).slug == tenant.slug

    loaded = ReadModel.get_database(database.id)
    assert loaded.tenant_id == tenant.id
    assert loaded.status == :pending
    assert loaded.node == nil

    stored = Smolsqls.Repo.get!(Smolsqls.ControlPlane.Database, database.id)
    assert %DateTime{} = loaded.inserted_at
    assert DateTime.compare(loaded.inserted_at, stored.inserted_at) == :eq

    loaded_token =
      ReadModel.get_database_token_by_hash(Smolsqls.Secrets.hash(database.auth_token))

    assert loaded_token.database_id == database.id
    assert loaded_token.enabled

    loaded_placed = ReadModel.get_database(placed.id)
    assert loaded_placed.status == :active
    assert loaded_placed.node == to_string(Node.self())
    assert loaded_placed.file_path == placed.file_path
  end

  test "limits and snapshot_generation ride the COPY snapshot" do
    tenant = tenant_fixture()

    {:ok, tenant} =
      tenant
      |> Ecto.Changeset.change(limits: %{"max_databases" => 3})
      |> Smolsqls.Repo.update()

    database = placed_database_fixture(tenant, %{}, limits: %{"rate_limit_rps" => 9})

    {:ok, _} = Smolsqls.DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
    assert :ok = Smolsqls.DataPlane.idle_stop_database(database)

    assert :ok = Snapshot.load()

    assert ReadModel.get_tenant(tenant.id).limits == %{"max_databases" => 3}

    loaded = ReadModel.get_database(database.id)
    assert loaded.limits == %{"rate_limit_rps" => 9}
    assert loaded.snapshot_generation == 1
  end

  test "authenticate paths serve from the read model once ready" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    Snapshot.load()
    ReadModel.mark_ready()
    on_exit(&ReadModel.mark_not_ready/0)

    assert {:ok, %{id: tenant_id}} = Smolsqls.ControlPlane.authenticate_tenant(tenant.api_key)
    assert tenant_id == tenant.id

    assert {:ok, %{id: db_id}} =
             Smolsqls.ControlPlane.authenticate_database(database.id, database.auth_token)

    assert db_id == database.id

    assert {:error, :unauthorized} =
             Smolsqls.ControlPlane.authenticate_database(database.id, "wrong")
  end
end
