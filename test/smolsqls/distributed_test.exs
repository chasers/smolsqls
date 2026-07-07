defmodule Smolsqls.DistributedTest do
  @moduledoc """
  Multi-node tests: spins up a real peer BEAM node, places a database
  server there, and verifies that `:syn` makes it discoverable across
  the cluster and that `Router.query/3` reaches it over `gen_rpc`
  (never Erlang distribution for the data path).

  Excluded by default; run with `mix test --include distributed`.
  Requires `epmd` to be running (`epmd -daemon`).
  """

  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag :tmp_dir

  @peer_gen_rpc_port 15_370

  alias Smolsqls.DataPlane.Registry
  alias Smolsqls.DataPlane.Router

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start(:smolsqls_primary, %{name_domain: :shortnames})
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    {:ok, peer_pid, peer_node} = :peer.start_link(%{name: peer_name()})

    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    peer_env =
      for app <- [:smolsqls, :phoenix, :logger, :gen_rpc], do: {app, Application.get_all_env(app)}

    :ok = :erpc.call(peer_node, Application, :put_all_env, [peer_env, [persistent: true]])

    :ok =
      :erpc.call(peer_node, Application, :put_env, [
        :gen_rpc,
        :tcp_server_port,
        @peer_gen_rpc_port,
        [persistent: true]
      ])

    {:ok, _} = :erpc.call(peer_node, Application, :ensure_all_started, [:smolsqls])
    :ok = :erpc.call(peer_node, Ecto.Adapters.SQL.Sandbox, :mode, [Smolsqls.Repo, :auto])

    previous_config = Application.get_env(:gen_rpc, :client_config_per_node)

    Application.put_env(
      :gen_rpc,
      :client_config_per_node,
      {:internal, %{peer_node => @peer_gen_rpc_port}}
    )

    on_exit(fn ->
      Application.put_env(:gen_rpc, :client_config_per_node, previous_config)
    end)

    %{peer_pid: peer_pid, peer_node: peer_node, tmp_dir: tmp_dir}
  end

  test "a database on a peer node is discoverable via syn and queryable via gen_rpc",
       %{peer_pid: peer_pid, peer_node: peer_node, tmp_dir: tmp_dir} do
    database_id = "dist-db-#{System.unique_integer([:positive])}"
    file_path = Path.join(tmp_dir, database_id <> ".db")

    {:ok, remote_pid} = start_remote_server(peer_node, database_id, file_path)

    assert node(remote_pid) == peer_node

    wait_until(fn -> Registry.whereis(database_id) == remote_pid end)
    assert {:ok, ^peer_node} = Registry.owner_node(database_id)

    assert {:ok, _} = Router.query(database_id, "CREATE TABLE t (v TEXT)")

    assert {:ok, %{num_changes: 1}} =
             Router.query(database_id, "INSERT INTO t VALUES (?)", ["from-primary"])

    assert {:ok, %{rows: [["from-primary"]]}} = Router.query(database_id, "SELECT v FROM t")

    assert File.exists?(file_path)
  end

  test "restore_from_file/2 drains and swaps the file on the owning node",
       %{peer_node: peer_node, tmp_dir: tmp_dir} do
    database_id = "dist-db-#{System.unique_integer([:positive])}"
    file_path = Path.join(tmp_dir, database_id <> ".db")

    {:ok, _remote_pid} = start_remote_server(peer_node, database_id, file_path)
    wait_until(fn -> Registry.whereis(database_id) != :undefined end)

    assert {:ok, _} = Router.query(database_id, "CREATE TABLE t (v TEXT)")
    assert {:ok, _} = Router.query(database_id, "INSERT INTO t VALUES ('keep')")

    backup_path = Path.join(tmp_dir, "backup.db")
    assert {:ok, _} = Router.snapshot_into(database_id, backup_path)
    assert {:ok, _} = Router.query(database_id, "DELETE FROM t")

    database = %Smolsqls.ControlPlane.Database{
      id: database_id,
      node: to_string(peer_node),
      file_path: file_path
    }

    assert :ok = Smolsqls.DataPlane.restore_from_file(database, backup_path)

    wait_until(fn -> Registry.whereis(database_id) != :undefined end)
    assert {:ok, ^peer_node} = Registry.owner_node(database_id)
    assert {:ok, %{rows: [["keep"]]}} = Router.query(database_id, "SELECT v FROM t")
  end

  test "a losing cross-node activation race never opens the file",
       %{peer_node: peer_node, tmp_dir: tmp_dir} do
    database_id = "dist-db-#{System.unique_integer([:positive])}"
    peer_file = Path.join(tmp_dir, "peer-" <> database_id <> ".db")
    local_file = Path.join(tmp_dir, "local-" <> database_id <> ".db")

    {:ok, remote_pid} = start_remote_server(peer_node, database_id, peer_file)
    wait_until(fn -> Registry.whereis(database_id) == remote_pid end)

    assert {:error, {:already_started, ^remote_pid}} =
             GenServer.start(
               Smolsqls.DataPlane.Database.Server,
               [database_id: database_id, file_path: local_file],
               name: Smolsqls.DataPlane.Registry.via(database_id)
             )

    refute File.exists?(local_file)
    assert {:ok, ^peer_node} = Registry.owner_node(database_id)
  end

  test "syn deregisters the database when the peer goes down",
       %{peer_pid: peer_pid, peer_node: peer_node, tmp_dir: tmp_dir} do
    database_id = "dist-db-#{System.unique_integer([:positive])}"
    file_path = Path.join(tmp_dir, database_id <> ".db")

    {:ok, remote_pid} = start_remote_server(peer_node, database_id, file_path)

    wait_until(fn -> Registry.whereis(database_id) == remote_pid end)

    :peer.stop(peer_pid)

    wait_until(fn -> Registry.whereis(database_id) == :undefined end)
    assert {:error, :database_not_running} = Router.query(database_id, "SELECT 1")
  end

  test "a database idled on one node activates on another with its data",
       %{peer_node: peer_node} do
    database = checked_out_shipped_database()

    {:ok, _} =
      database
      |> Smolsqls.ControlPlane.Database.placement_changeset(%{
        status: :active,
        node: to_string(peer_node)
      })
      |> Smolsqls.Repo.update()

    database = Smolsqls.ControlPlane.get_database(database.id)
    assert database.snapshot_generation == 1

    assert {:ok, pid} = Smolsqls.DataPlane.activate_database(database)
    assert node(pid) == peer_node

    wait_until(fn -> Registry.whereis(database.id) == pid end)
    assert {:ok, %{rows: [["survives"]]}} = Router.query(database.id, "SELECT v FROM t")
  end

  test "draining a live node hands off hot databases and reassigns placement",
       %{peer_node: peer_node} do
    database = checked_out_shipped_database()

    {:ok, _} =
      database
      |> Smolsqls.ControlPlane.Database.placement_changeset(%{
        status: :active,
        node: to_string(peer_node)
      })
      |> Smolsqls.Repo.update()

    database = Smolsqls.ControlPlane.get_database(database.id)
    assert {:ok, pid} = Smolsqls.DataPlane.activate_database(database)
    assert node(pid) == peer_node
    wait_until(fn -> Registry.whereis(database.id) == pid end)

    assert {:ok, %{reassigned: 1, handed_off: 1}} = Smolsqls.Drain.drain(to_string(peer_node))

    wait_until(fn -> Registry.whereis(database.id) == :undefined end)
    assert Smolsqls.ControlPlane.get_database(database.id).node == to_string(Node.self())

    assert {:ok, %{rows: [["survives"]]}} = Router.query(database.id, "SELECT v FROM t")
    assert {:ok, owner} = Registry.owner_node(database.id)
    assert owner == Node.self()
  end

  defp checked_out_shipped_database do
    Ecto.Adapters.SQL.Sandbox.checkout(Smolsqls.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Smolsqls.Repo, {:shared, self()})

    tenant = Smolsqls.Fixtures.tenant_fixture()
    database = Smolsqls.Fixtures.database_fixture(tenant)

    {:ok, database} = Smolsqls.DataPlane.place_database_locally(database)

    on_exit(fn ->
      case Registry.whereis(database.id) do
        pid when is_pid(pid) ->
          if node(pid) == Node.self(), do: GenServer.stop(pid, :normal)

        :undefined ->
          :ok
      end

      Smolsqls.DataPlane.delete_local_files(database.file_path)
    end)

    {:ok, _} = Router.query(database.id, "CREATE TABLE t (v TEXT)")
    {:ok, _} = Router.query(database.id, "INSERT INTO t VALUES ('survives')")

    :ok = Smolsqls.DataPlane.idle_stop_database(database)
    Smolsqls.DataPlane.delete_local_files(database.file_path)

    Smolsqls.ControlPlane.get_database(database.id)
  end

  test "reconciler does not reclaim databases owned by a live node",
       %{peer_node: peer_node} do
    Ecto.Adapters.SQL.Sandbox.checkout(Smolsqls.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Smolsqls.Repo, {:shared, self()})

    tenant = Smolsqls.Fixtures.tenant_fixture()
    database = Smolsqls.Fixtures.database_fixture(tenant)

    data_dir = Application.fetch_env!(:smolsqls, :data_dir)
    file_path = Path.join([data_dir, tenant.id, database.id <> ".db"])
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, "stale local copy")
    on_exit(fn -> File.rm(file_path) end)

    {:ok, _} =
      database
      |> Smolsqls.ControlPlane.Database.placement_changeset(%{
        status: :active,
        node: to_string(peer_node),
        file_path: file_path
      })
      |> Smolsqls.Repo.update()

    Smolsqls.DataPlane.Reconciler.reconcile()

    assert Smolsqls.ControlPlane.get_database(database.id).node == to_string(peer_node)
  end

  defp start_remote_server(peer_node, database_id, file_path) do
    via = :erpc.call(peer_node, Smolsqls.DataPlane.Registry, :via, [database_id])

    :erpc.call(peer_node, GenServer, :start, [
      Smolsqls.DataPlane.Database.Server,
      [database_id: database_id, file_path: file_path],
      [name: via]
    ])
  end

  defp peer_name do
    :"smolsqls_peer_#{System.unique_integer([:positive])}"
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, 0) do
    assert fun.()
  end

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end
end
