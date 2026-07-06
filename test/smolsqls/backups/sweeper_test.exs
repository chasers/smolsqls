defmodule Smolsqls.Backups.SweeperTest do
  use Smolsqls.DataCase

  import Smolsqls.Fixtures

  alias Smolsqls.Backups
  alias Smolsqls.Backups.Sweeper
  alias Smolsqls.DataPlane

  setup do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")

    on_exit(fn -> Backups.delete_all(database) end)

    %{database: database}
  end

  test "sweep/0 backs up an active database with no recent backup", %{database: database} do
    assert Backups.list(database) == []

    assert Sweeper.sweep() >= 1

    assert [backup] = Backups.list(database)
    assert backup.origin == :automatic
    assert backup.size_bytes > 0
  end

  test "sweep/0 skips a database already backed up within the window", %{database: database} do
    {:ok, _} = Backups.trigger(database)

    assert Sweeper.sweep() == 0
    assert length(Backups.list(database)) == 1
  end
end
