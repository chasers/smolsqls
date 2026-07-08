defmodule Smolsqls.ExpirySweeperTest do
  use Smolsqls.DataCase

  import Smolsqls.Fixtures

  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane
  alias Smolsqls.ExpirySweeper
  alias Smolsqls.Repo

  defp expire_at(database, seconds_from_now) do
    at = DateTime.add(DateTime.utc_now(), seconds_from_now, :second)
    {:ok, database} = database |> Ecto.Changeset.change(expires_at: at) |> Repo.update()
    database
  end

  test "due_for_expiry/2 only returns databases past their expiry" do
    tenant = tenant_fixture()
    expired = placed_database_fixture(tenant) |> expire_at(-60)
    future = placed_database_fixture(tenant) |> expire_at(3600)
    permanent = placed_database_fixture(tenant)

    due_ids = DateTime.utc_now() |> ControlPlane.due_for_expiry() |> Enum.map(& &1.id)

    assert expired.id in due_ids
    refute future.id in due_ids
    refute permanent.id in due_ids
  end

  test "sweep/0 deletes a database whose expiry has passed" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant) |> expire_at(-60)

    assert ExpirySweeper.sweep() >= 1

    assert ControlPlane.get_database(database.id) == nil
    refute File.exists?(database.file_path)
  end

  test "sweep/0 leaves a not-yet-expired database alone" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant) |> expire_at(3600)

    assert ExpirySweeper.sweep() == 0
    assert ControlPlane.get_database(database.id) != nil
  end

  test "sweep/0 defers an expired database that still has branches" do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant)
    {:ok, _} = DataPlane.query(source.id, "CREATE TABLE t (v TEXT)")
    :ok = DataPlane.idle_stop_database(source)
    source = ControlPlane.get_database(source.id)

    {:ok, branch} =
      Smolsqls.branch_database(source, %{"name" => "branch-#{System.unique_integer([:positive])}"})

    on_exit(fn ->
      DataPlane.Supervisor.stop_database(branch.id)
      if branch.file_path, do: DataPlane.delete_local_files(branch.file_path)
    end)

    expire_at(source, -60)

    ExpirySweeper.sweep()

    assert ControlPlane.get_database(source.id) != nil
  end
end
