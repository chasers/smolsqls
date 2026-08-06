defmodule Smolsqls.DataPlane.ChangeStreamTest do
  use ExUnit.Case, async: false

  alias Smolsqls.DataPlane.ChangeStream
  alias Smolsqls.DataPlane.Database.Server

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    database_id = "change-stream-test-#{System.unique_integer([:positive])}"
    file_path = Path.join(tmp_dir, database_id <> ".db")

    start_supervised!({Server, database_id: database_id, file_path: file_path})

    {:ok, _} = Server.query(database_id, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

    %{database_id: database_id}
  end

  test "subscriber receives insert events with the record", %{database_id: database_id} do
    :ok = ChangeStream.subscribe(database_id)

    {:ok, _} = Server.query(database_id, "INSERT INTO t (v) VALUES (?)", ["hello"])

    assert_receive {:smolsqls_change, ^database_id, event}, 1_000
    assert event.action == :insert
    assert event.table == "t"
    assert event.rowid == 1
    assert event.record == %{"id" => 1, "v" => "hello"}
  end

  test "update events carry the new record, delete events carry no record",
       %{database_id: database_id} do
    {:ok, _} = Server.query(database_id, "INSERT INTO t (v) VALUES (?)", ["before"])

    :ok = ChangeStream.subscribe(database_id)

    {:ok, _} = Server.query(database_id, "UPDATE t SET v = ? WHERE id = 1", ["after"])

    assert_receive {:smolsqls_change, ^database_id,
                    %{action: :update, table: "t", rowid: 1, record: %{"v" => "after"}}},
                   1_000

    {:ok, _} = Server.query(database_id, "DELETE FROM t WHERE id = 1")

    assert_receive {:smolsqls_change, ^database_id,
                    %{action: :delete, table: "t", rowid: 1, record: nil}},
                   1_000
  end

  test "one statement changing many rows emits one event per row",
       %{database_id: database_id} do
    :ok = ChangeStream.subscribe(database_id)

    {:ok, _} =
      Server.query(database_id, "INSERT INTO t (v) VALUES (?), (?), (?)", ["a", "b", "c"])

    for rowid <- 1..3 do
      assert_receive {:smolsqls_change, ^database_id, %{action: :insert, rowid: ^rowid}}, 1_000
    end
  end

  test "unsubscribed processes receive nothing", %{database_id: database_id} do
    :ok = ChangeStream.subscribe(database_id)
    :ok = ChangeStream.unsubscribe(database_id)

    {:ok, _} = Server.query(database_id, "INSERT INTO t (v) VALUES (?)", ["quiet"])

    refute_receive {:smolsqls_change, _database_id, _event}, 200
  end

  test "a disabled server publishes nothing until re-enabled", %{tmp_dir: tmp_dir} do
    database_id = "cs-toggle-test-#{System.unique_integer([:positive])}"
    file_path = Path.join(tmp_dir, database_id <> ".db")

    database = %Smolsqls.ControlPlane.Database{
      id: database_id,
      change_stream_enabled: false
    }

    start_supervised!(
      {Server, database_id: database_id, file_path: file_path, database: database},
      id: :toggle_server
    )

    {:ok, _} = Server.query(database_id, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

    :ok = ChangeStream.subscribe(database_id)

    {:ok, _} = Server.query(database_id, "INSERT INTO t (v) VALUES (?)", ["silent"])
    refute_receive {:smolsqls_change, _database_id, _event}, 200

    :ok = Server.set_change_stream(database_id, true)

    {:ok, _} = Server.query(database_id, "INSERT INTO t (v) VALUES (?)", ["loud"])
    assert_receive {:smolsqls_change, ^database_id, %{record: %{"v" => "loud"}}}, 1_000
  end

  test "subscriber_count tracks joins, leaves, and subscriber death",
       %{database_id: database_id} do
    assert ChangeStream.subscriber_count(database_id) == 0

    :ok = ChangeStream.subscribe(database_id)
    assert ChangeStream.subscriber_count(database_id) == 1

    subscriber =
      spawn(fn ->
        :ok = ChangeStream.subscribe(database_id)

        receive do
          :stop -> :ok
        end
      end)

    Smolsqls.Wait.until(fn -> ChangeStream.subscriber_count(database_id) == 2 end)

    send(subscriber, :stop)
    Smolsqls.Wait.until(fn -> ChangeStream.subscriber_count(database_id) == 1 end)

    :ok = ChangeStream.unsubscribe(database_id)
    assert ChangeStream.subscriber_count(database_id) == 0
  end
end
