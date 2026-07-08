defmodule Smolsqls.BranchTest do
  use Smolsqls.DataCase

  import Smolsqls.Fixtures

  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane

  defp cleanup_on_exit(database) do
    on_exit(fn ->
      DataPlane.Supervisor.stop_database(database.id)

      if database.file_path do
        DataPlane.delete_local_files(database.file_path)
      end
    end)
  end

  test "branch_database/2 forks an independent copy from the latest snapshot" do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant)

    {:ok, _} = DataPlane.query(source.id, "CREATE TABLE t (v TEXT)")
    {:ok, _} = DataPlane.query(source.id, "INSERT INTO t VALUES ('parent-data')")
    :ok = DataPlane.idle_stop_database(source)

    source = ControlPlane.get_database(source.id)
    assert source.snapshot_generation >= 1

    assert {:ok, branch} =
             Smolsqls.branch_database(source, %{
               "name" => "branch-#{System.unique_integer([:positive])}"
             })

    cleanup_on_exit(branch)

    assert branch.id != source.id
    assert branch.source_database_id == source.id
    assert %DateTime{} = branch.branch_point_at
    assert branch.status == :active
    assert is_binary(branch.auth_token)

    assert {:ok, %{rows: [["parent-data"]]}} = DataPlane.query(branch.id, "SELECT v FROM t")

    assert {:ok, _} = DataPlane.query(branch.id, "INSERT INTO t VALUES ('branch-only')")

    assert {:ok, %{rows: [["parent-data"]]}} =
             DataPlane.query(source.id, "SELECT v FROM t ORDER BY v")
  end

  test "branch_database/2 refuses when the source has no snapshot to branch from" do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant)

    assert source.snapshot_generation in [nil, 0]

    assert {:error, :no_snapshot} =
             Smolsqls.branch_database(source, %{
               "name" => "branch-#{System.unique_integer([:positive])}"
             })
  end

  test "branch_database/2 counts against the tenant database limit" do
    {:ok, tenant} =
      tenant_fixture()
      |> Ecto.Changeset.change(limits: %{"max_databases" => 1})
      |> Smolsqls.Repo.update()

    source = placed_database_fixture(tenant)
    {:ok, _} = DataPlane.query(source.id, "CREATE TABLE t (v TEXT)")
    :ok = DataPlane.idle_stop_database(source)
    source = ControlPlane.get_database(source.id)

    assert {:error, :database_limit_reached} =
             Smolsqls.branch_database(source, %{
               "name" => "branch-#{System.unique_integer([:positive])}"
             })
  end
end
