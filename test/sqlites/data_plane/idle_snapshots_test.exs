defmodule Sqlites.DataPlane.IdleSnapshotsTest do
  use Sqlites.DataCase

  import Sqlites.Fixtures

  alias Sqlites.ControlPlane
  alias Sqlites.DataPlane.IdleSnapshots

  @moduletag :tmp_dir

  test "object_key/1 is database-addressed" do
    tenant = tenant_fixture()
    database = database_fixture(tenant)

    assert IdleSnapshots.object_key(database) ==
             "idle-snapshots/#{tenant.id}/#{database.id}/latest.db"
  end

  test "local generation round-trips through the sidecar", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "db.db")

    assert IdleSnapshots.local_generation(file_path) == 0

    :ok = IdleSnapshots.write_local_generation(file_path, 7)
    assert IdleSnapshots.local_generation(file_path) == 7

    File.write!(IdleSnapshots.marker_path(file_path), "garbage")
    assert IdleSnapshots.local_generation(file_path) == 0
  end

  test "ship/2 uploads, bumps the generation, and stamps the sidecar", %{tmp_dir: tmp_dir} do
    tenant = tenant_fixture()
    database = database_fixture(tenant)
    database = %{database | file_path: Path.join(tmp_dir, database.id <> ".db")}

    snapshot_path = Path.join(tmp_dir, "snapshot.db")
    File.write!(snapshot_path, "snapshot-bytes")

    assert {:ok, updated} = IdleSnapshots.ship(database, snapshot_path)
    assert updated.snapshot_generation == 1
    assert updated.last_snapshot_at

    assert IdleSnapshots.local_generation(database.file_path) == 1
    assert ControlPlane.get_database(database.id).snapshot_generation == 1

    dest = Path.join(tmp_dir, "restored.db")
    assert :ok = IdleSnapshots.restore(updated, dest)
    assert File.read!(dest) == "snapshot-bytes"
    assert IdleSnapshots.local_generation(dest) == 1
  end

  test "restore/2 refuses when nothing has ever shipped", %{tmp_dir: tmp_dir} do
    tenant = tenant_fixture()
    database = database_fixture(tenant)

    assert {:error, :no_idle_snapshot} =
             IdleSnapshots.restore(database, Path.join(tmp_dir, "dest.db"))
  end
end
