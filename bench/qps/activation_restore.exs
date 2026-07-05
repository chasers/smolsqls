# Phase 6 §4: activation paths and idle-churn shipping economics.
#
#   mix run bench/qps/activation_restore.exs
#
# Measures, against the phase 5 machinery:
#   - activation storm split by path: cache-hit (file current on the
#     volume) vs restore-from-object-store (file wiped after the idle
#     snapshot shipped)
#   - per-idle-stop ship cost: VACUUM INTO + object-store PUT latency
#     and snapshot bytes, i.e. what every hot->cold cycle costs until
#     exact read-only classification (phase 6 §1) lands
#
# The dev object store is the local filesystem; real S3 adds network
# on top of every restore/ship number below.

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

  def percentile(sorted, p) do
    Enum.at(sorted, min(length(sorted) - 1, floor(length(sorted) * p)))
  end

  def latency_line(label, latencies_us) do
    sorted = Enum.sort(latencies_us)

    IO.puts(
      "  #{label}: p50 #{format_us(percentile(sorted, 0.5))} · " <>
        "p99 #{format_us(percentile(sorted, 0.99))} · max #{format_us(List.last(sorted))}"
    )
  end

  defp format_us(us) when us >= 1_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_us(us), do: "#{us}µs"
end

{:ok, tenant} =
  ControlPlane.create_tenant(%{
    "name" => "Bench",
    "slug" => "bench-#{System.unique_integer([:positive])}"
  })

{:ok, tenant} =
  tenant
  |> Ecto.Changeset.change(limits: %{"max_databases" => 1_000_000})
  |> Sqlites.Repo.update()

db_count = 500

IO.puts("== setup: #{db_count} databases with a small working set ==")

dbs =
  for i <- 1..db_count do
    {:ok, db} = Sqlites.create_database(tenant, %{"name" => "act-#{i}"})
    {:ok, _} = DataPlane.query(db.id, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

    for j <- 1..20 do
      {:ok, _} = DataPlane.query(db.id, "INSERT INTO t (v) VALUES (?)", ["row-#{j}"])
    end

    db
  end

IO.puts("== idle-stop ship cost (#{db_count} dirty sessions) ==")

{ship_latencies, seconds} =
  Bench.measure("#{db_count} idle-stops, each shipping a snapshot", fn ->
    dbs
    |> Task.async_stream(
      fn db ->
        started = System.monotonic_time(:microsecond)
        :ok = DataPlane.idle_stop_database(db)
        System.monotonic_time(:microsecond) - started
      end,
      max_concurrency: 50,
      timeout: 120_000
    )
    |> Enum.map(fn {:ok, us} -> us end)
  end)

IO.puts("  -> #{Bench.ops_per_sec(db_count, seconds)} ships/s (50 concurrent)")
Bench.latency_line("ship latency", ship_latencies)

snapshot_bytes =
  Application.fetch_env!(:sqlites, :data_dir)
  |> Path.join("object_store/idle-snapshots/#{tenant.id}")
  |> Path.join("*/latest.db")
  |> Path.wildcard()
  |> Enum.map(&File.stat!(&1).size)

IO.puts(
  "  snapshot size: avg #{div(Enum.sum(snapshot_bytes), max(length(snapshot_bytes), 1))} bytes " <>
    "over #{length(snapshot_bytes)} objects"
)

IO.puts("\n== activation storm: cache hit (file still on the volume) ==")

{hit_latencies, seconds} =
  Bench.measure("#{db_count} concurrent cold first-queries", fn ->
    dbs
    |> Task.async_stream(
      fn db ->
        started = System.monotonic_time(:microsecond)
        {:ok, _} = DataPlane.query(db.id, "SELECT count(*) FROM t")
        System.monotonic_time(:microsecond) - started
      end,
      max_concurrency: 200,
      timeout: 120_000
    )
    |> Enum.map(fn {:ok, us} -> us end)
  end)

IO.puts("  -> #{Bench.ops_per_sec(db_count, seconds)} activations/s")
Bench.latency_line("first-query latency", hit_latencies)

IO.puts("\n== activation storm: restore from the object store (volume wiped) ==")

for db <- dbs do
  :ok = DataPlane.idle_stop_database(db)
  db = ControlPlane.get_database(db.id)
  DataPlane.delete_local_files(db.file_path)
end

fresh = Enum.map(dbs, &ControlPlane.get_database(&1.id))

{restore_latencies, seconds} =
  Bench.measure("#{db_count} concurrent cold first-queries, no local file", fn ->
    fresh
    |> Task.async_stream(
      fn db ->
        started = System.monotonic_time(:microsecond)
        {:ok, _} = DataPlane.query(db.id, "SELECT count(*) FROM t")
        System.monotonic_time(:microsecond) - started
      end,
      max_concurrency: 200,
      timeout: 120_000
    )
    |> Enum.map(fn {:ok, us} -> us end)
  end)

IO.puts("  -> #{Bench.ops_per_sec(db_count, seconds)} activations/s")
Bench.latency_line("first-query latency", restore_latencies)

IO.puts("\n== idle-churn economics ==")

cycles_per_hour_per_db = 4

IO.puts(
  "  at #{cycles_per_hour_per_db} hot->cold cycles/db/hour, a 100k-db node ships " <>
    "#{100_000 * cycles_per_hour_per_db} snapshots/hour " <>
    "(#{Float.round(100_000 * cycles_per_hour_per_db / 3600, 0)} PUTs/s) — every one of " <>
    "them redundant for read-only sessions until §1 lands"
)

IO.puts("\n== cleanup ==")

for db <- fresh do
  Sqlites.remove_database(db)
end

{:ok, _} = Sqlites.delete_tenant(tenant)
IO.puts("done")
