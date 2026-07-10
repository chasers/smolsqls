defmodule Smolsqls.RegionalPlacementTest do
  use Smolsqls.DataCase

  import Smolsqls.Fixtures

  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane
  alias Smolsqls.DataPlane.Placement

  @region "gcp-us-central1"
  @other_region "gcp-europe-west1"

  setup do
    Application.put_env(:smolsqls, :regions, [@region, @other_region])
    Application.put_env(:smolsqls, :default_region, @region)

    on_exit(fn ->
      Application.put_env(:smolsqls, :regions, [])
      Application.put_env(:smolsqls, :default_region, nil)
    end)

    :ok
  end

  describe "region on create" do
    test "defaults to the configured default region and derives cloud" do
      tenant = tenant_fixture()
      {:ok, database} = ControlPlane.create_database(tenant, %{"name" => "regdb"})

      assert database.region == @region
      assert database.cloud == "gcp"
    end

    test "honors an explicit valid region" do
      tenant = tenant_fixture()

      {:ok, database} =
        ControlPlane.create_database(tenant, %{"name" => "regdb", "region" => @other_region})

      assert database.region == @other_region
      assert database.cloud == "gcp"
    end

    test "rejects an unsupported region" do
      tenant = tenant_fixture()

      assert {:error, changeset} =
               ControlPlane.create_database(tenant, %{"name" => "regdb", "region" => "mars-1"})

      assert %{region: _} = errors_on(changeset)
    end
  end

  describe "branch inheritance" do
    test "a branch inherits its source's region" do
      tenant = tenant_fixture()

      {:ok, source} =
        ControlPlane.create_database(tenant, %{"name" => "src", "region" => @other_region})

      {:ok, branch} = ControlPlane.branch_database(source, %{"name" => "child"})

      assert branch.region == @other_region
      assert branch.cloud == "gcp"
    end
  end

  describe "Placement.pick_node/1" do
    test "picks a live node registered in the requested region" do
      {:ok, _} = ControlPlane.upsert_node(to_string(Node.self()), @region)

      assert Placement.pick_node(@region) == Node.self()
    end

    test "rejects a region with no live node" do
      {:ok, _} = ControlPlane.upsert_node(to_string(Node.self()), @region)

      assert Placement.pick_node(@other_region) == {:error, :no_capacity_in_region}
    end

    test "nil region stays load-based across the whole cluster" do
      assert Placement.pick_node(nil) == Node.self()
    end
  end

  describe "DataPlane.place_database/1 region wiring" do
    test "rejects placement when no live node serves the region" do
      tenant = tenant_fixture()
      database = database_fixture(tenant, %{"region" => @other_region})

      assert DataPlane.place_database(database) == {:error, :no_capacity_in_region}
    end

    test "places on a node registered in the requested region" do
      {:ok, _} = ControlPlane.upsert_node(to_string(Node.self()), @region)
      tenant = tenant_fixture()
      database = database_fixture(tenant, %{"region" => @region})
      {:ok, placed} = DataPlane.place_database(database)

      on_exit(fn ->
        DataPlane.Supervisor.stop_database(placed.id)
        if placed.file_path, do: DataPlane.delete_local_files(placed.file_path)
      end)

      assert placed.status == :active
      assert placed.region == @region
      assert placed.node == to_string(Node.self())
    end
  end

  describe "upsert_node/2" do
    test "is idempotent and refreshes region + cloud" do
      name = to_string(Node.self())
      {:ok, _} = ControlPlane.upsert_node(name, @region)
      {:ok, _} = ControlPlane.upsert_node(name, @other_region)

      assert ControlPlane.nodes_in_region(@other_region) == [name]
      assert ControlPlane.nodes_in_region(@region) == []
    end
  end
end
