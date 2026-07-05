defmodule Sqlites.DataPlane.CacheEvictorTest do
  use Sqlites.DataCase

  import Sqlites.Fixtures

  alias Sqlites.DataPlane
  alias Sqlites.DataPlane.CacheEvictor
  alias Sqlites.DataPlane.Registry

  setup do
    previous = Application.get_env(:sqlites, CacheEvictor)
    Application.put_env(:sqlites, CacheEvictor, high_water_bytes: 1, low_water_ratio: 0.8)

    on_exit(fn ->
      if previous do
        Application.put_env(:sqlites, CacheEvictor, previous)
      else
        Application.delete_env(:sqlites, CacheEvictor)
      end
    end)

    :ok
  end

  test "evicts cold shipped databases and activation restores them" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
    {:ok, _} = DataPlane.query(database.id, "INSERT INTO t VALUES ('cached')")

    idle_stop_and_settle(database)

    assert %{evicted: evicted} = CacheEvictor.sweep()
    assert evicted >= 1
    refute File.exists?(database.file_path)

    assert {:ok, %{rows: [["cached"]]}} = DataPlane.query(database.id, "SELECT v FROM t")
  end

  test "never evicts a hot database" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")

    CacheEvictor.sweep()

    assert File.exists?(database.file_path)
    assert is_pid(Registry.whereis(database.id))
  end

  test "never evicts a file written after its last ship" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
    idle_stop_and_settle(database)

    File.touch!(database.file_path, System.os_time(:second) + 10)

    CacheEvictor.sweep()

    assert File.exists?(database.file_path)
  end

  test "never evicts a never-shipped database" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    pid = Registry.whereis(database.id)

    ref = Process.monitor(pid)
    :ok = DataPlane.Supervisor.stop_database(database.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    wait_until(fn -> Registry.whereis(database.id) == :undefined end)

    CacheEvictor.sweep()

    assert File.exists?(database.file_path)
  end

  defp idle_stop_and_settle(database) do
    pid = Registry.whereis(database.id)
    ref = Process.monitor(pid)
    assert :ok = DataPlane.idle_stop_database(database)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    wait_until(fn -> Registry.whereis(database.id) == :undefined end)
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
