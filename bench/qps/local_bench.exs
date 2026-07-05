# QPS benchmarks against a single local node (full app running):
#
#   mix run bench/qps/local_bench.exs
#
# Measures: per-database serialized write ceiling, single-database read
# throughput, cross-database parallel write throughput, and the
# activation storm (N cold databases hit with their first query at
# once).

alias Sqlites.ControlPlane
alias Sqlites.DataPlane

defmodule Bench do
  def measure(label, fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    elapsed_us = System.monotonic_time(:microsecond) - start
    {result, elapsed_us / 1_000_000}
    |> tap(fn {_, s} -> IO.puts("#{label}: #{Float.round(s, 3)}s") end)
  end

  def ops_per_sec(count, seconds), do: Float.round(count / seconds, 0)
end

{:ok, tenant} =
  ControlPlane.create_tenant(%{"name" => "Bench", "slug" => "bench-#{System.unique_integer([:positive])}"})

{:ok, tenant} =
  tenant
  |> Ecto.Changeset.change(limits: %{"max_databases" => 1_000_000})
  |> Sqlites.Repo.update()

make_db = fn name ->
  {:ok, db} = Sqlites.create_database(tenant, %{"name" => name})
  db
end

IO.puts("== single-database serialized write ceiling ==")
db = make_db.("write-ceiling")
{:ok, _} = DataPlane.query(db.id, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

writes = 5_000

{_, seconds} =
  Bench.measure("#{writes} sequential inserts", fn ->
    for i <- 1..writes do
      {:ok, _} = DataPlane.query(db.id, "INSERT INTO t (v) VALUES (?)", ["v#{i}"])
    end
  end)

IO.puts("  -> #{Bench.ops_per_sec(writes, seconds)} writes/s (single writer)\n")

IO.puts("== single-database concurrent writers (contention) ==")

{_, seconds} =
  Bench.measure("#{writes} inserts from 50 concurrent callers", fn ->
    1..writes
    |> Task.async_stream(
      fn i -> {:ok, _} = DataPlane.query(db.id, "INSERT INTO t (v) VALUES (?)", ["c#{i}"]) end,
      max_concurrency: 50,
      timeout: 60_000
    )
    |> Stream.run()
  end)

IO.puts("  -> #{Bench.ops_per_sec(writes, seconds)} writes/s (through one GenServer)\n")

IO.puts("== single-database read throughput (50 concurrent) ==")
reads = 20_000

{_, seconds} =
  Bench.measure("#{reads} SELECTs", fn ->
    1..reads
    |> Task.async_stream(
      fn _ -> {:ok, _} = DataPlane.query(db.id, "SELECT v FROM t WHERE id = 1") end,
      max_concurrency: 50,
      timeout: 60_000
    )
    |> Stream.run()
  end)

IO.puts("  -> #{Bench.ops_per_sec(reads, seconds)} reads/s (serialized through the writer)\n")

IO.puts("== cross-database parallel writes (100 dbs, 50 writers) ==")
dbs = for i <- 1..100, do: make_db.("parallel-#{i}")

for pdb <- dbs do
  {:ok, _} = DataPlane.query(pdb.id, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
end

parallel_writes = 20_000

{_, seconds} =
  Bench.measure("#{parallel_writes} inserts spread over 100 dbs", fn ->
    1..parallel_writes
    |> Task.async_stream(
      fn i ->
        pdb = Enum.at(dbs, rem(i, 100))
        {:ok, _} = DataPlane.query(pdb.id, "INSERT INTO t (v) VALUES (?)", ["p#{i}"])
      end,
      max_concurrency: 50,
      timeout: 60_000
    )
    |> Stream.run()
  end)

IO.puts("  -> #{Bench.ops_per_sec(parallel_writes, seconds)} writes/s across databases\n")

IO.puts("== activation storm (1000 cold dbs, concurrent first queries) ==")
storm_dbs = for i <- 1..1_000, do: make_db.("storm-#{i}")

for sdb <- storm_dbs do
  {:ok, _} = DataPlane.query(sdb.id, "CREATE TABLE t (v TEXT)")
end

for sdb <- storm_dbs do
  :ok = DataPlane.Supervisor.stop_database(sdb.id)
end

{_, seconds} =
  Bench.measure("1000 concurrent cold first-queries", fn ->
    storm_dbs
    |> Task.async_stream(
      fn sdb -> {:ok, _} = DataPlane.query(sdb.id, "SELECT 1") end,
      max_concurrency: 200,
      timeout: 120_000
    )
    |> Stream.run()
  end)

IO.puts("  -> #{Bench.ops_per_sec(1000, seconds)} activations/s\n")

IO.puts("== cleanup ==")

for cleanup_db <- [db | dbs] ++ storm_dbs do
  Sqlites.remove_database(cleanup_db)
end

{:ok, _} = Sqlites.delete_tenant(tenant)
IO.puts("done")
