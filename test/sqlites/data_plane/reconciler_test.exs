defmodule Sqlites.DataPlane.ReconcilerTest do
  use Sqlites.DataCase

  import Sqlites.Fixtures

  alias Sqlites.ControlPlane
  alias Sqlites.ControlPlane.Database
  alias Sqlites.DataPlane.Reconciler

  test "claims a database whose file is local but record points elsewhere" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    {:ok, _} =
      database
      |> Database.placement_changeset(%{node: "departed@old-pod"})
      |> Repo.update()

    result = Reconciler.reconcile()
    assert result.claimed >= 1

    reclaimed = ControlPlane.get_database(database.id)
    assert reclaimed.node == to_string(Node.self())
    assert reclaimed.file_path == database.file_path
    assert File.exists?(reclaimed.file_path)
  end

  test "leaves correctly-placed databases untouched" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    before = ControlPlane.get_database(database.id)

    Reconciler.reconcile()

    after_reconcile = ControlPlane.get_database(database.id)
    assert after_reconcile.node == before.node
    assert after_reconcile.updated_at == before.updated_at
  end

  test "activation works after a claim (rename recovery end to end)" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    {:ok, _} = Sqlites.DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
    {:ok, _} = Sqlites.DataPlane.query(database.id, "INSERT INTO t VALUES ('survived')")
    :ok = Sqlites.DataPlane.Supervisor.stop_database(database.id)

    {:ok, _} =
      database
      |> Database.placement_changeset(%{node: "departed@old-pod"})
      |> Repo.update()

    Reconciler.reconcile()

    assert {:ok, %{rows: [["survived"]]}} =
             Sqlites.DataPlane.query(database.id, "SELECT v FROM t")
  end

  test "ignores non-database files in the data dir" do
    data_dir = Application.fetch_env!(:sqlites, :data_dir)
    junk_dir = Path.join(data_dir, "not-a-tenant")
    File.mkdir_p!(junk_dir)
    File.write!(Path.join(junk_dir, "notes.db"), "not sqlite")
    on_exit(fn -> File.rm_rf!(junk_dir) end)

    assert %{found: _, claimed: _} = Reconciler.reconcile()
  end
end
