# QPS benchmark — results

Local numbers: macOS arm64 (M-series, 10 cores), dev env, full app,
queries through `DataPlane.query/3`. Latency numbers: 3-pod kind
cluster on a 4GB Docker VM.

Two measurement eras:

- **phase 3** (2026-07-04, pre-idle-snapshots): plain query path, no
  leases, no telemetry, gen_rpc over TCP.
- **phase 5 re-baseline** (2026-07-04, `local_bench.exs` +
  `activation_restore.exs` + `evacuation.exs`): idle-snapshot
  shipping, writer leases, per-query telemetry, gen_rpc over TLS in
  kind. **Caveat:** the phase 5 locals were measured while the 3-pod
  kind cluster ran on the same machine; treat ±20% as noise here. A
  controlled A/B on the read loop initially attributed ~10–15% to the
  `telemetry_metrics_prometheus_core` handlers (shared-ETS contention:
  handlers run inline in the emitting process, and 50 readers hammer
  the same series keys). Swapping the aggregation backend to **Peep
  with striped storage** (one ETS table per scheduler) removed the
  overhead entirely — same noisy environment, ~21,200 reads/s with
  handlers attached vs ~16–20k across control runs, i.e. within
  noise — while nearly closing the gap to the phase 3 number.

## Single-node throughput (local)

| scenario | phase 3 | phase 5 re-baseline |
|---|---|---|
| single db, sequential inserts | ~9,900 writes/s | **~9,360 writes/s** |
| single db, 50 concurrent writers | ~9,450 writes/s | **~9,780 writes/s** |
| single db, 50 concurrent reads | ~25,000 reads/s | **~21,200 reads/s** after moving aggregation to Peep striped storage (first measured ~11,400 on `telemetry_metrics_prometheus_core`; see caveat above) |
| 100 dbs, 50 concurrent writers | ~12,650 writes/s | **~14,700 writes/s** |
| activation storm, 1,000 warm-file dbs | ~1,650 act/s | **~1,510 act/s** |

Writer-path throughput is unchanged: the lease check and dirty flag
are noise. The read loop was the only place per-query telemetry cost
showed up, and the Peep striped-storage backend eliminated it.

## Activation paths (phase 5 machinery, `activation_restore.exs`)

500 databases, ~20 rows each (avg snapshot 8KB), local-filesystem
object store — real S3 adds network on top of every number.

| path | throughput | first-query latency |
|---|---|---|
| cache hit (file current on volume) | ~1,435 act/s | p50 119ms · p99 209ms (under a 200-concurrent storm; solo warm activation is sub-ms) |
| restore from object store (volume wiped) | ~435 act/s | p50 435ms · p99 802ms |

Restore-path activation is ~3.3× slower than cache-hit even with a
local-FS "S3". This is the number the cache evictor's high-water mark
trades against.

For **solo** cold-start latency (not a storm) against **real MinIO/S3**,
swept across db sizes — plus the brand-new-db create→ready path — see
[`bench/cold_start/RESULTS.md`](../cold_start/RESULTS.md).

## Idle-stop ship cost (the §1 lever)

| metric | value |
|---|---|
| ships, 50 concurrent | ~355 ships/s |
| per-ship latency (VACUUM INTO + PUT + metadb bump) | p50 133ms · p99 190ms |
| snapshot size (tiny bench dbs) | 8KB |

Every hot→cold cycle ships, read-only or not, until exact
classification (phase 6 §1, punted) lands. Scale math: 100k dbs
cycling 4×/hour = 400k PUTs/hour ≈ 111 PUTs/s per node ≈ **$2/hour
per node in S3 PUT fees alone** at standard pricing — the concrete
justification for §1 when it's picked back up.

## Control-plane operations at density scale (`evacuation.exs`)

| operation | result |
|---|---|
| `Failover.evacuate/1`, 100k placement rows | **1.9s (~52,000 rows/s)** — auto-failover of a full-density node is seconds of metadb work |
| `Fence.sweep/0`, 2,000 hot local servers | ~227,000 servers/s checked — a 100k-server node sweeps in ~0.5s, comfortably inside the 30s cadence |

## Query latency (kind cluster, cross-pod)

| path | phase 3 (TCP) | phase 5 (gen_rpc TLS + dist TLS) |
|---|---|---|
| owner pod handles its own query | 35µs avg | **91µs avg · p99 497µs** |
| non-owner hop via gen_rpc | 387µs avg | **352–457µs avg · p99 0.7–1.3ms** (two runs) |

TLS on the query path is free at steady state — pooled gen_rpc
connections amortize the handshake, and the cross-pod averages
bracket the old plaintext number. The owner-local delta carries the
same telemetry/noise caveat as the local table.

## Not measured

- Hrana WebSocket connection ceiling per node — needs a proper
  load-generation harness; deferred until the protocol surface work.
- Sustained mixed read/write soak (hours) — deferred to a real cluster.
- Restore-path *storms* against real S3 (network) — still deferred; the
  local-FS numbers here are lower bounds. Solo cold-restore latency
  against real MinIO/S3 is now measured in
  [`bench/cold_start/RESULTS.md`](../cold_start/RESULTS.md), which also
  found (and fixed) a ~1 GB cold pull OOM-killing the owning pod — the S3
  restore/ship now stream to/from disk instead of buffering the whole
  object in memory.
