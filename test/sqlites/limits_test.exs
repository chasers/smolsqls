defmodule Sqlites.LimitsTest do
  use Sqlites.DataCase

  import Sqlites.Fixtures

  alias Sqlites.ControlPlane
  alias Sqlites.DataPlane
  alias Sqlites.Limits
  alias Sqlites.Repo

  describe "resolve/2" do
    test "resolves database over tenant over cluster defaults" do
      tenant = tenant_fixture()
      database = database_fixture(tenant)

      resolved = Limits.resolve(database, tenant)
      assert resolved.max_size_bytes == 1_073_741_824
      assert resolved.query_timeout_ms == 30_000
      assert resolved.rate_limit_rps == nil

      tenant =
        tenant |> Ecto.Changeset.change(limits: %{"max_size_bytes" => 500}) |> Repo.update!()

      assert Limits.resolve(database, tenant).max_size_bytes == 500

      database =
        database |> Ecto.Changeset.change(limits: %{"max_size_bytes" => 900}) |> Repo.update!()

      assert Limits.resolve(database, tenant).max_size_bytes == 900
    end

    test "looks the tenant up when not provided" do
      tenant = tenant_fixture()

      {:ok, tenant} =
        tenant
        |> Ecto.Changeset.change(limits: %{"query_timeout_ms" => 1_234})
        |> Repo.update()

      database = database_fixture(tenant)
      assert Limits.resolve(database).query_timeout_ms == 1_234
    end

    test "ignores unknown keys" do
      tenant = tenant_fixture()

      {:ok, tenant} =
        tenant
        |> Ecto.Changeset.change(limits: %{"not_a_limit" => 1})
        |> Repo.update()

      resolved = Limits.resolve(nil, tenant)
      refute Map.has_key?(resolved, :not_a_limit)
    end
  end

  describe "max databases per tenant" do
    test "create_database respects the tenant's limit" do
      tenant = tenant_fixture()

      {:ok, tenant} =
        tenant
        |> Ecto.Changeset.change(limits: %{"max_databases" => 2})
        |> Repo.update()

      assert {:ok, _} = ControlPlane.create_database(tenant, %{"name" => "one"})
      assert {:ok, _} = ControlPlane.create_database(tenant, %{"name" => "two"})

      assert {:error, :database_limit_reached} =
               ControlPlane.create_database(tenant, %{"name" => "three"})
    end
  end

  describe "max database size" do
    test "writes beyond max_size_bytes fail cleanly" do
      tenant = tenant_fixture()

      database =
        placed_database_fixture(tenant, %{}, limits: %{"max_size_bytes" => 65_536})

      {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v BLOB)")

      result =
        Enum.reduce_while(1..64, :ok, fn _, _ ->
          case DataPlane.query(database.id, "INSERT INTO t VALUES (randomblob(4096))") do
            {:ok, _} -> {:cont, :ok}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)

      assert {:error, message} = result
      assert message =~ "full"
    end
  end

  describe "query timeouts" do
    @slow_query """
    WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM c WHERE x < 100000000)
    SELECT count(*) FROM c
    """

    test "statement_timeout_ms interrupts a runaway statement" do
      tenant = tenant_fixture()

      database =
        placed_database_fixture(tenant, %{}, limits: %{"statement_timeout_ms" => 50})

      assert {:error, message} = DataPlane.query(database.id, @slow_query)
      assert message =~ "interrupt"
    end

    test "query_timeout_ms bounds the caller-side wait" do
      tenant = tenant_fixture()

      database =
        placed_database_fixture(tenant, %{},
          limits: %{"query_timeout_ms" => 50, "statement_timeout_ms" => 200}
        )

      limits = Sqlites.Limits.resolve(database)

      assert {:error, :query_timeout} =
               DataPlane.query(database.id, @slow_query, [], limits.query_timeout_ms)
    end
  end

  describe "idle TTL and hot-hours" do
    test "idle_ttl_ms limit overrides the cluster default" do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant, %{}, limits: %{"idle_ttl_ms" => 100})

      pid = DataPlane.Registry.whereis(database.id)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "max_hot_ms recycles a server despite steady traffic" do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant, %{}, limits: %{"max_hot_ms" => 150})

      pid = DataPlane.Registry.whereis(database.id)
      ref = Process.monitor(pid)

      keep_warm =
        Task.async(fn ->
          for _ <- 1..20 do
            DataPlane.query(database.id, "SELECT 1")
            Process.sleep(25)
          end
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      Task.await(keep_warm)
    end
  end
end
