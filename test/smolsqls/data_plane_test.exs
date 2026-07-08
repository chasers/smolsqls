defmodule Smolsqls.DataPlaneTest do
  use Smolsqls.DataCase

  import Smolsqls.Fixtures

  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane

  test "place_database/1 starts a server on this node and marks placement" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    assert database.status == :active
    assert database.node == to_string(Node.self())
    assert File.exists?(database.file_path)
    assert {:ok, node} = DataPlane.owner_node(database.id)
    assert node == Node.self()

    persisted = ControlPlane.get_database(database.id)
    assert persisted.file_path == database.file_path
    assert persisted.node == database.node
  end

  test "query/3 routes to the placed database" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    assert {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
    assert {:ok, _} = DataPlane.query(database.id, "INSERT INTO t VALUES (?)", ["hi"])
    assert {:ok, %{rows: [["hi"]]}} = DataPlane.query(database.id, "SELECT v FROM t")
  end

  test "query/3 returns an error for an unplaced database" do
    assert {:error, :database_not_running} = DataPlane.query("no-such-db", "SELECT 1")
  end

  test "query/3 activates a cold database on miss" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
    {:ok, _} = DataPlane.query(database.id, "INSERT INTO t VALUES ('warm')")

    :ok = DataPlane.Supervisor.stop_database(database.id)
    assert DataPlane.Registry.whereis(database.id) == :undefined

    assert {:ok, %{rows: [["warm"]]}} = DataPlane.query(database.id, "SELECT v FROM t")
    assert is_pid(DataPlane.Registry.whereis(database.id))
  end

  test "query/3 telemetry tags cold vs warm" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    parent = self()
    handler = "cold-warm-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:smolsqls, :query],
      fn _event, _measurements, metadata, _ -> send(parent, {:query_meta, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _} = DataPlane.query(database.id, "SELECT 1")
    assert_receive {:query_meta, %{cold: "false"}}

    :ok = DataPlane.Supervisor.stop_database(database.id)
    assert {:ok, _} = DataPlane.query(database.id, "SELECT 1")
    assert_receive {:query_meta, %{cold: "true"}}
  end

  test "query/3 does not activate a deleting database" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    :ok = DataPlane.Supervisor.stop_database(database.id)

    {:ok, _} = Smolsqls.ControlPlane.mark_deleting(database)

    assert {:error, :database_not_active} = DataPlane.query(database.id, "SELECT 1")
  end

  test "remove_database/1 stops the server, deletes the file and the record" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    file_path = database.file_path

    assert {:ok, _} = DataPlane.remove_database(database)
    refute File.exists?(file_path)
    assert ControlPlane.get_database(database.id) == nil
    assert {:error, :not_found} = DataPlane.owner_node(database.id)
  end

  describe "idle-snapshot shipping" do
    test "a dirty idle-stop ships; activation on a fresh volume restores the data" do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
      {:ok, _} = DataPlane.query(database.id, "INSERT INTO t VALUES ('survives')")

      assert :ok = DataPlane.idle_stop_database(database)
      assert DataPlane.Registry.whereis(database.id) == :undefined
      assert ControlPlane.get_database(database.id).snapshot_generation == 1

      DataPlane.delete_local_files(database.file_path)

      assert {:ok, %{rows: [["survives"]]}} = DataPlane.query(database.id, "SELECT v FROM t")
      assert DataPlane.IdleSnapshots.local_generation(database.file_path) == 1
    end

    test "every session ships on idle-stop, even read-only ones" do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
      assert :ok = DataPlane.idle_stop_database(database)
      assert ControlPlane.get_database(database.id).snapshot_generation == 1

      assert {:ok, _} = DataPlane.query(database.id, "SELECT * FROM t")
      database = ControlPlane.get_database(database.id)
      assert :ok = DataPlane.idle_stop_database(database)

      assert ControlPlane.get_database(database.id).snapshot_generation == 2
    end

    test "a stale local file is discarded and re-fetched" do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
      {:ok, _} = DataPlane.query(database.id, "INSERT INTO t VALUES ('current')")
      assert :ok = DataPlane.idle_stop_database(database)

      File.write!(database.file_path, "stale bytes from an old volume")
      DataPlane.IdleSnapshots.write_local_generation(database.file_path, 0)

      assert {:ok, %{rows: [["current"]]}} = DataPlane.query(database.id, "SELECT v FROM t")
      assert DataPlane.IdleSnapshots.local_generation(database.file_path) == 1
    end

    test "remove_database/1 also deletes the idle snapshot object" do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
      assert :ok = DataPlane.idle_stop_database(database)

      object_path =
        Application.fetch_env!(:smolsqls, :data_dir)
        |> Path.join("object_store")
        |> Path.join(DataPlane.IdleSnapshots.object_key(database))

      assert File.exists?(object_path)

      database = ControlPlane.get_database(database.id)
      assert {:ok, _} = DataPlane.remove_database(database)
      refute File.exists?(object_path)
    end
  end
end
