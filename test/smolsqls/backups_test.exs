defmodule Smolsqls.BackupsTest do
  use Smolsqls.DataCase

  import Smolsqls.Fixtures

  alias Smolsqls.Backups
  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane
  alias Smolsqls.DataPlane.Database.Server

  setup do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
    {:ok, _} = DataPlane.query(database.id, "INSERT INTO t VALUES ('original')")

    on_exit(fn -> Backups.delete_all(database) end)

    %{database: database}
  end

  test "trigger/1 snapshots through the writer and records the artifact", %{database: database} do
    assert {:ok, backup} = Backups.trigger(database)
    assert backup.size_bytes > 0
    assert backup.origin == :manual
    assert backup.object_key =~ "backups/#{database.tenant_id}/#{database.id}/"

    assert [listed] = Backups.list(database)
    assert listed.id == backup.id
  end

  test "trigger_automatic/1 snapshots a hot database through the writer", %{database: database} do
    assert DataPlane.database_hot?(database.id)

    assert {:ok, backup} = Backups.trigger_automatic(database)
    assert backup.origin == :automatic
    assert backup.size_bytes > 0
    assert [^backup] = Backups.list(database)
  end

  test "trigger_automatic/1 promotes the idle snapshot for a cold database", %{
    database: database
  } do
    :ok = Server.idle_stop(database.id)
    refute DataPlane.database_hot?(database.id)

    cold = ControlPlane.get_database(database.id)
    assert cold.snapshot_generation > 0

    assert {:ok, backup} = Backups.trigger_automatic(cold)
    assert backup.origin == :automatic
    assert backup.size_bytes > 0

    assert :ok = Backups.restore(cold, backup.id)
    assert {:ok, %{rows: [["original"]]}} = DataPlane.query(database.id, "SELECT v FROM t")
  end

  test "due_for_backup/2 lists active databases missing a recent backup", %{database: database} do
    assert database.id in due_ids(DateTime.utc_now())

    {:ok, _} = Backups.trigger(database)

    refute database.id in due_ids(DateTime.add(DateTime.utc_now(), -1, :hour))
    assert database.id in due_ids(DateTime.add(DateTime.utc_now(), 1, :hour))
  end

  defp due_ids(cutoff), do: Enum.map(Backups.due_for_backup(cutoff), & &1.id)

  test "sla_stats/1 flags an active database past the window with no recent backup", %{
    database: database
  } do
    assert %{in_breach: 0} = Backups.sla_stats(:timer.hours(28))

    old = DateTime.add(DateTime.utc_now(), -30, :hour)

    Smolsqls.ControlPlane.Database
    |> where([d], d.id == ^database.id)
    |> Repo.update_all(set: [inserted_at: old])

    stats = Backups.sla_stats(:timer.hours(28))
    assert stats.in_breach >= 1
    assert stats.oldest_age_seconds >= 28 * 3600

    {:ok, _} = Backups.trigger(database)
    assert %{in_breach: 0} = Backups.sla_stats(:timer.hours(28))
  end

  test "restore/2 round-trips data through the object store", %{database: database} do
    {:ok, backup} = Backups.trigger(database)
    {:ok, _} = DataPlane.query(database.id, "DELETE FROM t")
    assert {:ok, %{rows: [[0]]}} = DataPlane.query(database.id, "SELECT count(*) FROM t")

    assert :ok = Backups.restore(database, backup.id)
    assert {:ok, %{rows: [["original"]]}} = DataPlane.query(database.id, "SELECT v FROM t")
  end

  test "restore/2 with an unknown backup id fails", %{database: database} do
    assert {:error, :backup_not_found} = Backups.restore(database, "nope")
    assert {:error, :backup_not_found} = Backups.restore(database, Ecto.UUID.generate())
  end

  test "delete_all/1 removes rows and artifacts", %{database: database} do
    {:ok, backup} = Backups.trigger(database)
    assert :ok = Backups.delete_all(database)

    assert Backups.list(database) == []

    assert {:error, :not_found} =
             Smolsqls.ObjectStore.fetch_to_file(backup.object_key, "/tmp/nope.db")
  end

  test "list/1 is empty for a fresh database", %{database: database} do
    assert Backups.list(database) == []
  end
end
