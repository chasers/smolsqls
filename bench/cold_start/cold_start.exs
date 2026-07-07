# Cold-start latency: how long a caller waits for a first result when a
# database is not hot. Two paths:
#
#   A) brand-new db — create -> place -> open empty file -> first query.
#      Placement starts the server at create time, so the first query is
#      served by an already-warm server; the user-visible number is the
#      create call itself.
#   B) cold pull from the object store — warm a db to a target size,
#      idle-stop (ships a VACUUM INTO snapshot to the store), wipe the
#      local file on the owning node, then time the SOLO first query that
#      restores from the store + opens + serves. Solo (not a storm) is the
#      real single-request cold-start number; activation_restore.exs already
#      covers aggregate throughput under a 200-concurrent storm.
#
# In-cluster (real MinIO/S3, 3-pod topology) via bench/cold_start/run.sh.
# Locally for a fast lower-bound smoke (local-FS object store is a copy, not
# a network pull):
#
#   mix run bench/cold_start/cold_start.exs

alias Smolsqls.ControlPlane
alias Smolsqls.DataPlane

defmodule Bench do
  def time_us(fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    {result, System.monotonic_time(:microsecond) - started}
  end

  def percentile(sorted, p),
    do: Enum.at(sorted, min(length(sorted) - 1, floor(length(sorted) * p)))

  def stats(label, us) do
    sorted = Enum.sort(us)

    IO.puts(
      "  #{label}: n=#{length(us)} · p50 #{fmt(percentile(sorted, 0.5))} · " <>
        "p99 #{fmt(percentile(sorted, 0.99))} · max #{fmt(List.last(sorted))}"
    )
  end

  def fmt(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 2)}s"
  def fmt(us) when us >= 1_000, do: "#{Float.round(us / 1_000, 1)}ms"
  def fmt(us), do: "#{round(us)}µs"

  def bytes(b) when b >= 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 2)}GiB"
  def bytes(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)}MiB"
  def bytes(b) when b >= 1024, do: "#{Float.round(b / 1024, 1)}KiB"
  def bytes(b), do: "#{b}B"

  def file_size_on(node, path) do
    case :erpc.call(node, File, :stat, [path]) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end
end

{:ok, tenant} =
  ControlPlane.create_tenant(%{
    "name" => "ColdStart",
    "slug" => "cold-#{System.unique_integer([:positive])}"
  })

{:ok, tenant} =
  tenant
  |> Ecto.Changeset.change(
    limits: %{"max_databases" => 1_000_000, "max_size_bytes" => 8_589_934_592}
  )
  |> Smolsqls.Repo.update()

Smolsqls.ReadModel.put_tenant(tenant)
Process.sleep(2_000)

IO.puts("== Scenario A: brand-new db cold start (create -> ready) ==")

a_reps = 30

a =
  for i <- 1..a_reps do
    {{:ok, db}, create_us} =
      Bench.time_us(fn -> Smolsqls.create_database(tenant, %{"name" => "new-#{i}"}) end)

    {{:ok, _}, query_us} = Bench.time_us(fn -> DataPlane.query(db.id, "SELECT 1") end)
    Smolsqls.remove_database(db)
    {create_us, query_us, create_us + query_us}
  end

Bench.stats("create", Enum.map(a, &elem(&1, 0)))
Bench.stats("first query (server warm from create)", Enum.map(a, &elem(&1, 1)))
Bench.stats("end-to-end create->ready", Enum.map(a, &elem(&1, 2)))

IO.puts("\n== Scenario B: cold pull from object store (solo restore latency) ==")

blob = :binary.copy("x", 1_000_000)

sweep = [
  {"brand-new (empty)", 0, 5},
  {"~1MB", 1, 5},
  {"~10MB", 10, 5},
  {"~100MB", 100, 4},
  {"~1GB", 1000, 2}
]

for {label, mb, reps} <- sweep do
  results =
    for _ <- 1..reps do
      {:ok, db} =
        Smolsqls.create_database(tenant, %{
          "name" => "cold-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = DataPlane.query(db.id, "CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)")

      for _ <- 1..mb//1 do
        {:ok, _} = DataPlane.query(db.id, "INSERT INTO t (v) VALUES (?)", [blob])
      end

      :ok = DataPlane.idle_stop_database(db)
      db = ControlPlane.get_database(db.id)
      owner = String.to_existing_atom(db.node)
      :ok = :erpc.call(owner, DataPlane, :delete_local_files, [db.file_path])

      {result, restore_us} =
        Bench.time_us(fn -> DataPlane.query(db.id, "SELECT count(*) FROM t", [], 300_000) end)

      restored_bytes =
        case result do
          {:ok, _} -> Bench.file_size_on(owner, db.file_path)
          _ -> 0
        end

      Smolsqls.remove_database(db)
      {result, restore_us, restored_bytes}
    end

  {ok, failed} = Enum.split_with(results, fn {r, _, _} -> match?({:ok, _}, r) end)
  avg_bytes = div(Enum.sum(Enum.map(ok, &elem(&1, 2))), max(length(ok), 1))

  IO.puts("  [#{label}] restored on-disk ~#{Bench.bytes(avg_bytes)}")

  if ok != [], do: Bench.stats("cold restore first-query", Enum.map(ok, &elem(&1, 1)))

  if failed != [] do
    reason = failed |> hd() |> elem(0)
    IO.puts("  ⚠ #{length(failed)}/#{reps} restore(s) FAILED — e.g. #{inspect(reason)}")
  end
end

IO.puts("\n== cleanup ==")
{:ok, _} = Smolsqls.delete_tenant(tenant)
IO.puts("done")
