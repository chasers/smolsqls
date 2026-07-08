# Cold-start latency — results

How long a caller waits for a first result when a database is **not hot**.
Measured **in-cluster** on the kind 3-pod cluster (`bench/cold_start/run.sh`),
against the **real MinIO/S3** object store over the cluster network — the only
path that exercises a real S3 GET on the cold-restore path. Single kind node,
~3.9 GiB RAM shared across all pods (3× smolsqls + postgres + minio +
operator), no per-pod memory limit.

Run: `2026-07-07`, `bench/cold_start/cold_start.exs` via `run.sh smolsqls-0`.

## Scenario A — brand-new db (create → ready)

Placement starts the database server (opens the empty `exqlite` file) at
**create** time, so a brand-new db is already hot on its first query. The
user-visible cost is the `create_database/2` call; the first query is served
warm.

| step | p50 | p99 | max |
|---|---|---|---|
| `create_database/2` | 4.8ms | 19.0ms | 19.0ms |
| first query (server warm from create) | 152µs | 572µs | 572µs |
| end-to-end create → ready | 4.9ms | 19.5ms | 19.5ms |

n=30. A new database is queryable ~5ms after `create` returns; there is no
separate cold first-query penalty because create already placed and opened it.

## Scenario B — cold pull from the object store (solo restore latency)

Warm a db to a target size, `idle_stop_database/1` (ships a `VACUUM INTO`
snapshot to MinIO), wipe the local file on the **owning node**, then time the
**solo** first query that restores from the store + opens + serves. Solo (not
a 200-concurrent storm) is the real single-request cold-start number;
`bench/qps/activation_restore.exs` covers aggregate throughput under a storm.

Measured on the current build (streaming + gzip) with **realistic** row data
— typed relational rows (int id, a random uuid/hash, vocabulary text for
name/email/note, ISO timestamps, a numeric amount) so it compresses like a
real database rather than a synthetic extreme. `logical` is the on-disk db
size; `on S3` is the gzipped object actually shipped/pulled.

| db size | logical | on S3 | ratio | restore p50 | p99 | n |
|---|---|---|---|---|---|---|
| empty | 8 KB | 216 B | — | 4.0ms | 8.6ms | 5 |
| ~1 MB | 992 KiB | 281 KiB | 3.5× | 11.5ms | 16.2ms | 5 |
| ~10 MB | 9.7 MiB | 2.7 MiB | 3.5× | 92.3ms | 100.7ms | 5 |
| ~100 MB | 95.5 MiB | 27.2 MiB | 3.5× | 731.7ms | 804.4ms | 4 |
| ~1 GB | 954 MiB | 271 MiB | 3.5× | 8.22s | 8.22s | 2 |

The data compresses a steady **~3.5×**, so a cold db costs ~3.5× less to
store and to pull over the wire. Below ~1 MB the restore is a fixed **~4ms
floor** — activation, syn registration, a small MinIO GET, opening the
connection. Above ~10 MB it is dominated by decompression + writing the full
logical size to disk, roughly **~8ms per logical MiB**.

**On this loopback network gzip makes the restore slower, not faster.** The
pre-gzip streaming path ran ~2.0ms/logical-MiB (100 MiB → 230ms, 1 GiB →
1.73s); with gzip the same 1 GiB is 8.22s, because you download 3.5× fewer
bytes but still inflate and write the full 954 MiB — and on same-node MinIO
the bytes you saved were nearly free to move. The win is **S3 storage +
transfer cost** (3.5× less), and cold-pull *latency* only turns positive when
the network is the bottleneck — real cross-AZ/region S3, where moving 271 MB
instead of 954 MB outweighs the inflate CPU. See
[Compression](#compression-gzip-in-the-object-store).

### ~1 GB used to OOM-kill the owning pod — fixed by streaming

Before the fix, the 1 GB bucket **could not complete**: restoring it
OOM-killed `smolsqls-0` (`OOMKilled`, exit 137, restart 19→20).
`Smolsqls.ObjectStore.S3.fetch_to_file/2` read the **entire object into a
single in-memory binary** (`Req.get(...) |> body` then `File.write!`), so a
cold pull's peak memory was ~the db size — fatal for a 1 GB db on this
~3.9 GiB node. The **ship** side (`put_file/2`, `File.read!` + `Req.put
body:`) had the same flaw and would OOM first, on `idle_stop`.

Both paths now **stream**: the restore downloads into a `.partial` file via
`Req … into: File.stream!` and atomically renames on success; the ship
uploads with `body: File.stream!(path, 1 MiB)` + explicit `content-length`
(`UNSIGNED-PAYLOAD` sigv4). The full 1 GB cycle now completes with **0 pod
restarts** — ship ~3.8s, restore ~1.7s (measured pre-gzip; the sweep above
has the current compressed numbers), `[[1000]]` rows intact. This matters in
prod because the default `max_size_bytes` is **1 GiB**
(`config :smolsqls, Smolsqls.Limits`), so a legitimately-sized database that
goes cold could previously OOM its node on the next request.

## Compression (gzip in the object store)

Objects are now stored **gzip-compressed**, transparently and streaming in
both directions (`ObjectStore.S3`): `put_file` deflates the source to a temp
and uploads it with the uncompressed length in `x-amz-meta-logical-length`;
`fetch_to_file` streams the object into a `.partial`, then — if the gzip
magic bytes are present — `safeInflate`s it to disk in bounded increments
(so an extreme ratio can't balloon memory), else renames it (objects written
before compression still restore). Validated in-cluster:

| check | result |
|---|---|
| extreme-ratio stress | a **402×** object (1001 MB from 2.49 MB, repeated byte) restores `[[1000]]` with **0 pod restarts** — bounded `safeInflate` neutralizes the decompression-bomb path |
| back-compat | a raw (pre-gzip) object restores byte-identical (magic-byte fallback) |
| `size_bytes` = logical | `put_file` **and** server-side `copy` both report 5,000,000 (metadata preserved through COPY) |
| incompressible data | 5 MB random → 5.0 MB stored (~1×, gzip framing overhead only) |

**Tradeoff.** With realistic data the store holds **~3.5× fewer bytes** (see
the sweep above) — a direct S3 storage + transfer saving on every cold db.
The cost is decompression CPU + writing the full logical size on restore,
which on a fast (loopback) network makes cold pulls *slower* (1 GiB: 1.73s
uncompressed → 8.22s), since the bytes saved were nearly free to move.
Against real cross-AZ/region S3, moving 271 MB instead of 954 MB should
offset or beat that CPU. If the latency ever dominates, zstd (better ratio,
faster inflate) or skipping compression when it doesn't pay are options —
noted in the tracker (task #33).

## Environment caveats

- Numbers are from a single kind node under memory pressure (minio has 36
  historical restarts); treat ±20% as noise, especially the tail.
- MinIO is same-node in kind, so the network hop is loopback-fast — real S3
  (cross-AZ) will add round-trip latency on top of every restore, most
  visibly on the small-db floor.
- `litestream stop failed … database not found` warnings during the run are
  benign: these dbs have litestream disabled, so the stop is a no-op.

## See also

- `bench/qps/RESULTS.md` — activation **storm** throughput (cache-hit vs
  restore) and idle-stop ship cost, against a local-FS object store.
