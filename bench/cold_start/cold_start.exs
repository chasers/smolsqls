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
#      covers aggregate throughput under a 200-concurrent storm. The fill is
#      fresh random bytes per row: the store gzip-compresses objects, so
#      incompressible data keeps each size equal to the bytes actually
#      shipped and pulled (a repeated byte would compress ~400x and make the
#      sweep meaningless).
#
# In-cluster (real MinIO/S3, 3-pod topology) via bench/cold_start/run.sh.
# Locally for a fast lower-bound smoke (local-FS object store is a copy, not
# a network pull):
#
#   mix run bench/cold_start/cold_start.exs

alias Smolsqls.ControlPlane
alias Smolsqls.DataPlane
alias Smolsqls.DataPlane.IdleSnapshots

defmodule Bench do
  @names ~w(alice bob carol dave erin frank grace heidi ivan judy mallory olivia peggy trent victor walter xavier yolanda)
  @domains ~w(example.com mail.test acme.io corp.net data.org)
  @words ~w(the quick brown fox jumps over lazy dog invoice payment order shipped pending review account balance updated created region customer note summary total draft synced queued retried expired refunded)

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

  def gen_row do
    uuid = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    name = Enum.random(@names)
    email = "#{name}#{:rand.uniform(9999)}@#{Enum.random(@domains)}"

    created_at =
      "2026-#{pad(:rand.uniform(12))}-#{pad(:rand.uniform(28))}T" <>
        "#{pad(:rand.uniform(23))}:#{pad(:rand.uniform(59))}:#{pad(:rand.uniform(59))}Z"

    amount = :rand.uniform(10_000_000) / 100
    note = Enum.map_join(1..(15 + :rand.uniform(35)), " ", fn _ -> Enum.random(@words) end)
    [uuid, name, email, created_at, amount, note]
  end

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  def page_size(db_id) do
    {:ok, r} = DataPlane.query(db_id, "PRAGMA page_size")
    r.rows |> hd() |> hd()
  end

  def fill_to(_db_id, target, _page_size) when target <= 0, do: :ok

  def fill_to(db_id, target, page_size) do
    batch = 1000
    placeholders = Enum.map_join(1..batch, ",", fn _ -> "(?,?,?,?,?,?)" end)
    sql = "INSERT INTO t (uuid, name, email, created_at, amount, note) VALUES " <> placeholders
    fill_loop(db_id, target, page_size, sql, batch)
  end

  defp fill_loop(db_id, target, page_size, sql, batch) do
    args = Enum.flat_map(1..batch, fn _ -> gen_row() end)
    {:ok, _} = DataPlane.query(db_id, sql, args)

    if page_count(db_id) * page_size >= target,
      do: :ok,
      else: fill_loop(db_id, target, page_size, sql, batch)
  end

  defp page_count(db_id) do
    {:ok, r} = DataPlane.query(db_id, "PRAGMA page_count")
    r.rows |> hd() |> hd()
  end

  def stored_size(key) do
    cfg = Application.fetch_env!(:smolsqls, Smolsqls.ObjectStore)

    if cfg[:adapter] == Smolsqls.ObjectStore.S3 do
      req =
        Req.new()
        |> ReqS3.attach(
          aws_sigv4: [
            access_key_id: cfg[:access_key_id],
            secret_access_key: cfg[:secret_access_key]
          ],
          aws_endpoint_url_s3: cfg[:endpoint]
        )

      case Req.head(req, url: "s3://#{cfg[:bucket]}/#{key}") do
        {:ok, resp} ->
          case Req.Response.get_header(resp, "content-length") do
            [length | _] -> String.to_integer(length)
            [] -> 0
          end

        _ ->
          0
      end
    else
      Application.fetch_env!(:smolsqls, :data_dir)
      |> Path.join("object_store")
      |> Path.join(key)
      |> File.stat()
      |> case do
        {:ok, stat} -> stat.size
        _ -> 0
      end
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

sweep = [
  {"brand-new (empty)", 0, 5},
  {"~1MB", 1, 5},
  {"~10MB", 10, 5},
  {"~100MB", 100, 4},
  {"~1GB", 1000, 2}
]

schema =
  "CREATE TABLE t (id INTEGER PRIMARY KEY, uuid TEXT, name TEXT, " <>
    "email TEXT, created_at TEXT, amount REAL, note TEXT)"

for {label, mb, reps} <- sweep do
  results =
    for _ <- 1..reps do
      {:ok, db} =
        Smolsqls.create_database(tenant, %{
          "name" => "cold-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = DataPlane.query(db.id, schema)
      Bench.fill_to(db.id, mb * 1_000_000, Bench.page_size(db.id))

      :ok = DataPlane.idle_stop_database(db)
      db = ControlPlane.get_database(db.id)
      owner = String.to_existing_atom(db.node)
      stored = Bench.stored_size(IdleSnapshots.object_key(db))
      :ok = :erpc.call(owner, DataPlane, :delete_local_files, [db.file_path])

      {result, restore_us} =
        Bench.time_us(fn -> DataPlane.query(db.id, "SELECT count(*) FROM t", [], 300_000) end)

      restored_bytes =
        case result do
          {:ok, _} -> Bench.file_size_on(owner, db.file_path)
          _ -> 0
        end

      Smolsqls.remove_database(db)
      {result, restore_us, restored_bytes, stored}
    end

  {ok, failed} = Enum.split_with(results, fn {r, _, _, _} -> match?({:ok, _}, r) end)
  avg_logical = div(Enum.sum(Enum.map(ok, &elem(&1, 2))), max(length(ok), 1))
  avg_stored = div(Enum.sum(Enum.map(ok, &elem(&1, 3))), max(length(ok), 1))
  ratio = Float.round(avg_logical / max(avg_stored, 1), 1)

  IO.puts(
    "  [#{label}] logical ~#{Bench.bytes(avg_logical)} · on store ~#{Bench.bytes(avg_stored)} " <>
      "(#{ratio}x compression)"
  )

  if ok != [], do: Bench.stats("cold restore first-query", Enum.map(ok, &elem(&1, 1)))

  if failed != [] do
    reason = failed |> hd() |> elem(0)
    IO.puts("  ⚠ #{length(failed)}/#{reps} restore(s) FAILED — e.g. #{inspect(reason)}")
  end
end

IO.puts("\n== cleanup ==")
{:ok, _} = Smolsqls.delete_tenant(tenant)
IO.puts("done")
