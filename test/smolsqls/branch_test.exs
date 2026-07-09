defmodule Smolsqls.BranchTest do
  use Smolsqls.DataCase

  import Smolsqls.Fixtures

  alias Smolsqls.ControlPlane
  alias Smolsqls.ControlPlane.Database
  alias Smolsqls.DataPlane
  alias Smolsqls.DataPlane.{IdleSnapshots, Litestream}

  defp with_litestream_stub(tmp_dir, restore_src, fun),
    do: with_litestream_stub(tmp_dir, restore_src, now_range(), fun)

  defp with_litestream_stub(tmp_dir, restore_src, {earliest, latest}, fun) do
    stub = Path.join(tmp_dir, "litestream-stub")

    File.write!(stub, """
    #!/bin/sh
    if [ "$1" = "restore" ]; then cp "#{restore_src}" "$3"; exit 0; fi
    if [ "$1" = "ltx" ]; then printf '%s' '#{ltx_json(earliest, latest)}'; exit 0; fi
    exit 1
    """)

    File.chmod!(stub, 0o755)
    previous = Application.get_env(:smolsqls, Litestream)

    Application.put_env(:smolsqls, Litestream,
      enabled: true,
      replica_url_prefix: "s3://bucket/ls",
      binary: stub
    )

    try do
      fun.()
    after
      case previous do
        nil -> Application.delete_env(:smolsqls, Litestream)
        value -> Application.put_env(:smolsqls, Litestream, value)
      end
    end
  end

  defp now_range do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {DateTime.add(now, -10 * 86_400, :second), DateTime.add(now, -3600, :second)}
  end

  defp ltx_json(%DateTime{} = earliest, %DateTime{} = latest) do
    ~s([{"level":0,"min_txid":"0000000000000001","max_txid":"0000000000000001",) <>
      ~s("size":646,"timestamp":"#{DateTime.to_iso8601(earliest)}"},) <>
      ~s({"level":0,"min_txid":"0000000000000002","max_txid":"0000000000000002",) <>
      ~s("size":229,"timestamp":"#{DateTime.to_iso8601(latest)}"}])
  end

  defp valid_seed_db(tenant, tmp_dir) do
    source = placed_database_fixture(tenant, %{"litestream_enabled" => true})
    {:ok, _} = DataPlane.query(source.id, "CREATE TABLE seeded (v TEXT)")
    :ok = DataPlane.idle_stop_database(source)
    source = ControlPlane.get_database(source.id)

    seed = Path.join(tmp_dir, "seed-#{System.unique_integer([:positive])}.db")
    :ok = Smolsqls.ObjectStore.fetch_to_file(IdleSnapshots.object_key(source), seed)
    {source, seed}
  end

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

  test "branch_database/2 rejects a point in time when the source has no litestream" do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant)

    assert {:error, :point_in_time_requires_litestream} =
             Smolsqls.branch_database(source, %{
               "name" => "branch-#{System.unique_integer([:positive])}",
               "timestamp" => "2026-07-01T00:00:00Z"
             })
  end

  test "branch_database/2 rejects an invalid or out-of-window point in time" do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant, %{"litestream_enabled" => true})

    assert {:error, :invalid_timestamp} =
             Smolsqls.branch_database(source, %{"name" => "b1", "timestamp" => "nonsense"})

    stale = DateTime.utc_now() |> DateTime.add(-40 * 24 * 3600, :second) |> DateTime.to_iso8601()

    assert {:error, :timestamp_out_of_window} =
             Smolsqls.branch_database(source, %{"name" => "b2", "timestamp" => stale})
  end

  test "branch_database/2 cleans up a partial branch when seeding fails" do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant)

    {:ok, source} =
      source |> Ecto.Changeset.change(snapshot_generation: 3) |> Smolsqls.Repo.update()

    name = "branch-#{System.unique_integer([:positive])}"

    assert {:error, _reason} = Smolsqls.branch_database(source, %{"name" => name})

    refute Enum.any?(ControlPlane.list_databases(tenant), &(&1.name == name))
  end

  test "a branch name is reusable after the branch is deleted" do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant)
    {:ok, _} = DataPlane.query(source.id, "CREATE TABLE t (v TEXT)")
    :ok = DataPlane.idle_stop_database(source)
    source = ControlPlane.get_database(source.id)

    name = "reused-#{System.unique_integer([:positive])}"

    {:ok, first} = Smolsqls.branch_database(source, %{"name" => name})
    assert {:ok, _} = Smolsqls.remove_database(first)

    {:ok, second} = Smolsqls.branch_database(source, %{"name" => name})
    cleanup_on_exit(second)

    assert second.name == name
    assert second.id != first.id
  end

  @tag :tmp_dir
  test "seed_branch_from_pitr uploads a point-in-time restore to the branch's snapshot key",
       %{tmp_dir: tmp_dir} do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant, %{"litestream_enabled" => true})

    branch = %Database{
      id: Ecto.UUID.generate(),
      tenant_id: tenant.id,
      name: "b",
      status: :pending
    }

    src = Path.join(tmp_dir, "restore-src")
    File.write!(src, "branch-bytes")

    with_litestream_stub(tmp_dir, src, fn ->
      assert :ok = DataPlane.seed_branch_from_pitr(source, branch, ~U[2026-07-01 00:00:00Z])
    end)

    dest = Path.join(tmp_dir, "verify.db")
    assert :ok = Smolsqls.ObjectStore.fetch_to_file(IdleSnapshots.object_key(branch), dest)
    assert File.read!(dest) == "branch-bytes"
  end

  @tag :tmp_dir
  test "replica_range/1 reports the earliest and latest replicated timestamps",
       %{tmp_dir: tmp_dir} do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant, %{"litestream_enabled" => true})
    {earliest, latest} = now_range()

    src = Path.join(tmp_dir, "x")
    File.write!(src, "x")

    with_litestream_stub(tmp_dir, src, {earliest, latest}, fn ->
      assert {:ok, %{earliest: got_earliest, latest: got_latest}} =
               DataPlane.replica_range(source)

      assert DateTime.compare(got_earliest, earliest) == :eq
      assert DateTime.compare(got_latest, latest) == :eq
    end)
  end

  @tag :tmp_dir
  test "branch_database/2 clamps a point-in-time past the replica head to the latest point",
       %{tmp_dir: tmp_dir} do
    tenant = tenant_fixture()
    {source, seed} = valid_seed_db(tenant, tmp_dir)
    {earliest, latest} = now_range()
    beyond = DateTime.add(latest, 60, :second)

    with_litestream_stub(tmp_dir, seed, {earliest, latest}, fn ->
      assert {:ok, branch} =
               Smolsqls.branch_database(source, %{
                 "name" => "clamped",
                 "timestamp" => DateTime.to_iso8601(beyond)
               })

      cleanup_on_exit(branch)
      assert DateTime.compare(branch.branch_point_at, latest) == :eq
    end)
  end

  @tag :tmp_dir
  test "branch_database/2 keeps an in-range point-in-time as requested", %{tmp_dir: tmp_dir} do
    tenant = tenant_fixture()
    {source, seed} = valid_seed_db(tenant, tmp_dir)
    {earliest, latest} = now_range()
    in_range = DateTime.add(earliest, 86_400, :second)

    with_litestream_stub(tmp_dir, seed, {earliest, latest}, fn ->
      assert {:ok, branch} =
               Smolsqls.branch_database(source, %{
                 "name" => "in-range",
                 "timestamp" => DateTime.to_iso8601(in_range)
               })

      cleanup_on_exit(branch)
      assert DateTime.compare(branch.branch_point_at, in_range) == :eq
    end)
  end

  @tag :tmp_dir
  test "branch_database/2 rejects a point-in-time older than the replica's earliest point",
       %{tmp_dir: tmp_dir} do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant, %{"litestream_enabled" => true})
    {earliest, latest} = now_range()
    too_old = DateTime.add(earliest, -86_400, :second)

    src = Path.join(tmp_dir, "x")
    File.write!(src, "x")

    with_litestream_stub(tmp_dir, src, {earliest, latest}, fn ->
      assert {:error, :timestamp_out_of_window} =
               Smolsqls.branch_database(source, %{
                 "name" => "too-old",
                 "timestamp" => DateTime.to_iso8601(too_old)
               })
    end)
  end
end
