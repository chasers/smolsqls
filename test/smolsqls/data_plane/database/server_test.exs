defmodule Smolsqls.DataPlane.Database.ServerTest do
  use ExUnit.Case, async: false

  alias Smolsqls.DataPlane.Database.Server

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    database_id = "server-test-#{System.unique_integer([:positive])}"
    file_path = Path.join(tmp_dir, database_id <> ".db")

    start_supervised!({Server, database_id: database_id, file_path: file_path})

    %{database_id: database_id, file_path: file_path}
  end

  test "runs DDL, writes, and reads", %{database_id: database_id} do
    assert {:ok, _} = Server.query(database_id, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

    assert {:ok, %{num_changes: 2, last_insert_rowid: 2}} =
             Server.query(database_id, "INSERT INTO t (v) VALUES (?), (?)", ["a", "b"])

    assert {:ok, %{columns: ["id", "v"], rows: [[1, "a"], [2, "b"]]}} =
             Server.query(database_id, "SELECT * FROM t ORDER BY id")
  end

  test "returns errors for bad SQL without crashing", %{database_id: database_id} do
    assert {:error, message} = Server.query(database_id, "SELEC nope")
    assert message =~ "syntax error"

    assert {:error, message} = Server.query(database_id, "SELECT ?", [])
    assert message =~ "expected 1 arguments"

    assert {:ok, %{rows: [[1]]}} = Server.query(database_id, "SELECT 1")
  end

  test "registers in syn and is discoverable", %{database_id: database_id} do
    pid = Smolsqls.DataPlane.Registry.whereis(database_id)
    assert is_pid(pid)
    assert {:ok, node} = Smolsqls.DataPlane.Registry.owner_node(database_id)
    assert node == Node.self()
  end

  test "serializes concurrent writes through the single owner", %{database_id: database_id} do
    assert {:ok, _} = Server.query(database_id, "CREATE TABLE counter (n INTEGER)")
    assert {:ok, _} = Server.query(database_id, "INSERT INTO counter VALUES (0)")

    1..50
    |> Task.async_stream(
      fn _ -> Server.query(database_id, "UPDATE counter SET n = n + 1") end,
      max_concurrency: 20
    )
    |> Stream.run()

    assert {:ok, %{rows: [[50]]}} = Server.query(database_id, "SELECT n FROM counter")
  end

  test "stops after the idle TTL, kept alive by queries", %{tmp_dir: tmp_dir} do
    database_id = "ttl-test-#{System.unique_integer([:positive])}"
    file_path = Path.join(tmp_dir, database_id <> ".db")

    start_supervised!(
      {Server, database_id: database_id, file_path: file_path, idle_ttl: 300},
      id: :ttl_server
    )

    for _ <- 1..3 do
      Process.sleep(150)
      assert {:ok, _} = Server.query(database_id, "SELECT 1")
    end

    pid = Smolsqls.DataPlane.Registry.whereis(database_id)
    assert is_pid(pid)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert Smolsqls.DataPlane.Registry.whereis(database_id) == :undefined
  end

  test "denies ATTACH DATABASE", %{database_id: database_id, tmp_dir: tmp_dir} do
    other = Path.join(tmp_dir, "victim.db")

    assert {:error, message} =
             Server.query(database_id, "ATTACH DATABASE '#{other}' AS victim")

    assert message =~ "authoriz"
  end

  test "denies DETACH DATABASE", %{database_id: database_id} do
    assert {:error, message} = Server.query(database_id, "DETACH DATABASE main")
    assert message =~ "authoriz"
  end

  test "denies VACUUM", %{database_id: database_id} do
    assert {:ok, _} = Server.query(database_id, "CREATE TABLE t (v TEXT)")

    assert {:error, vacuum} = Server.query(database_id, "VACUUM")
    assert vacuum =~ "authoriz"

    assert {:error, vacuum_into} =
             Server.query(database_id, "VACUUM INTO '/tmp/smolsqls-escape.db'")

    assert vacuum_into =~ "authoriz"
    refute File.exists?("/tmp/smolsqls-escape.db")
  end

  test "snapshot_into bypasses the authorizer (privileged backup path)", %{
    database_id: database_id,
    tmp_dir: tmp_dir
  } do
    assert {:ok, _} = Server.query(database_id, "CREATE TABLE t (v TEXT)")
    assert {:ok, _} = Server.query(database_id, "INSERT INTO t VALUES ('x')")

    snapshot = Path.join(tmp_dir, "snap.db")
    assert {:ok, _} = Server.snapshot_into(database_id, snapshot)
    assert File.exists?(snapshot)
  end

  test "denies load_extension", %{database_id: database_id} do
    assert {:error, message} = Server.query(database_id, "SELECT load_extension('/nope.so')")
    assert message =~ "authoriz"
  end

  test "clears the authorizer between statements", %{database_id: database_id} do
    assert {:error, _} = Server.query(database_id, "ATTACH DATABASE ':memory:' AS x")

    assert {:ok, _} = Server.query(database_id, "CREATE TABLE t (v TEXT)")
    assert {:ok, %{num_changes: 1}} = Server.query(database_id, "INSERT INTO t VALUES ('ok')")
    assert {:ok, %{rows: [["ok"]]}} = Server.query(database_id, "SELECT v FROM t")
  end

  test "still allows temp tables and recursive CTEs", %{database_id: database_id} do
    assert {:ok, _} = Server.query(database_id, "CREATE TEMP TABLE tmp (n INTEGER)")
    assert {:ok, _} = Server.query(database_id, "INSERT INTO tmp VALUES (1), (2)")

    assert {:ok, %{rows: [[3]]}} =
             Server.query(
               database_id,
               "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 3) SELECT max(n) FROM c"
             )
  end

  test "persists data across a restart", %{database_id: database_id, file_path: file_path} do
    assert {:ok, _} = Server.query(database_id, "CREATE TABLE t (v TEXT)")
    assert {:ok, _} = Server.query(database_id, "INSERT INTO t VALUES ('kept')")

    :ok = Server.stop(database_id)
    start_supervised!({Server, [database_id: database_id, file_path: file_path]}, id: :restarted)

    assert {:ok, %{rows: [["kept"]]}} = Server.query(database_id, "SELECT v FROM t")
  end
end
