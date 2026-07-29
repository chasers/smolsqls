# The read-model cache

How every node serves auth and placement reads without putting Postgres on the
query path — and what happens to queries when Postgres is unreachable.

[`docs/architecture.md`](architecture.md) has the one-paragraph version; this is
the deep dive on the cache itself. Code: `Smolsqls.ReadModel` and the modules
under `lib/smolsqls/read_model/`.

## What problem it solves

Every query has to answer three metadata questions before it can touch SQLite:
which database does this token authenticate, where is that database placed, and
what limits apply. Asking Postgres each time puts the metadb on the hot path of
every request in the fleet; caching the whole metadb on every node — the previous
design — puts a copy of every row on every node whether it serves it or not.

Measured on representative rows (`:erts_debug.flat_size/1`), a full replica cost
upwards of **2 GB per node at 1M databases** before index tables — paid by every
node whether or not it served those databases, and rebuilt from scratch on every
boot.

So: hold **only the rows this node has recently been asked for**. Memory then
tracks a node's working set instead of the size of the fleet — around 135 MB for
50k active databases, against gigabytes for a full replica.

## What is cached

Four ETS tables, keyed on what the request path looks up by:

| table | key | contents |
|---|---|---|
| `databases` | `id` | the whole row |
| `tenants` | `id` | the whole row |
| `database_tokens` | `token_hash` | the whole row except `token_ciphertext` |
| `tenant_api_keys` | `token_hash` | the whole row except `token_ciphertext` |

**Rows are cached whole.** A cached row reads exactly like one loaded from
Postgres, so no caller needs to know where its row came from. An earlier version
of this cache held only the columns the query path read; it saved memory a
working-set cache does not need to save, and charged every reader an invisible
rule about which fields might be `nil`.

The one exception is `token_ciphertext`. It decrypts to a live secret, nothing on
a cached path reads it (`reveal` goes to Postgres), and caching it would leave
the secret in ETS on every node that ever authenticated that token — and in any
crash dump taken there. It is left out of the publication too, so it never enters
the replication stream. `Smolsqls.ReadModel.CachedRow` owns that one exclusion.

Cached rows are still **read-only**: an entry can be stale, so writes go to
Postgres by id. That is why `ControlPlane.mark_placed/3` takes an id and updates
by query — placement is written from the id alone and returns the fresh row, so a
cached copy never becomes the basis of a write.

Three paths populate an entry — a Postgres read on a miss (`ReadModel.Source`),
the WAL feed (`ReadModel.Row`), and local write-through — and all three must
produce the same shape, or a field would be `nil` depending on how a row happened
to get cached. `Smolsqls.ReadModel.CachedRowTest` fails if they drift, and it
fills every nullable column first: a row with `nil`s in it cannot detect a
dropped column, because "not populated" and "populated with nothing" look
identical.

### What it costs

Measured with `:erts_debug.flat_size/1` on representative rows:

| row | bytes | 50k entries | 250k entries (the default cap) |
|---|---|---|---|
| `databases` | ~1.6 KB | 77 MB | 385 MB |
| credential row | ~1.0 KB | 48 MB | 242 MB |

A realistic working set is the number that matters: ~135 MB across all four
tables for 50k active databases, against ~1.6 GB for `databases` alone if every
row in a 1M-database fleet were held. Whole rows are roughly 3× the old
projection, so **size `max_entries` to the node** — at the default it bounds the
four tables at about 1 GB combined, which is a ceiling, not a working figure.

## Reading

An entry is `{key, {:ok, row} | :missing, loaded_at}`.

- **Hit** — one `:ets.lookup/2`, and **no write**. A sliding TTL would stamp
  `last_used` on every read, and since these tables are `read_concurrency: true`
  with no `write_concurrency`, that write takes the whole-table lock — so the
  busiest database would serialize every lookup in the fleet. Keeping reads pure
  is the point.
- **Refresh-ahead** — a hit older than `ttl_ms / 2` (plus per-key
  `:erlang.phash2` jitter, so entries loaded together don't all refresh together)
  casts a reload and returns the cached row immediately. The caller never waits.
  A key seeing one request per half-TTL is therefore reloaded while still valid
  and never expires: that is what makes "frequent callers keep working" true, at
  about two writes per day per hot key instead of one per read.
- **Miss** — read through to Postgres, single-flighted per key: 500 concurrent
  requests for one cold database issue one query. The owner also re-checks the
  table before starting a load, so a reader that missed and then queued behind a
  load that has since finished does not issue a redundant read.
- **Negative caching** — a genuine miss caches `:missing` for
  `negative_ttl_ms`. Not an optimization: under the old full replica a miss was
  answered from ETS for free, so without it, spraying random bearer tokens turns
  into a metadb DoS.
- **Invalid keys** — a malformed id is answered without touching Postgres *or*
  the cache, so a client making ids up cannot fill the tables with junk.

## Writing

Every ETS write happens in the `ReadModel` process; the tables are `:protected`
so that is enforced rather than conventional.

| source | rule |
|---|---|
| local control-plane mutation (`put/2`) | caches unconditionally — the row was just written here and is about to be read back |
| WAL feed (`replace_if_cached/2`) | replaces the row **only if this node already holds the key**, so remote changes can never grow the cache back into a full replica. A held negative entry counts as held, so a create is not shadowed by a cached miss |
| delete, from either source | always applies, leaving a negative entry where one was held. This is how a revocation propagates immediately to every node caching the token |

### The mutation-during-load race

A load reads Postgres in a separate process, so a row can be deleted between the
read and the insert:

```
t0  miss on database D, load starts and reads the row
t1  D is deleted; the feed applies the delete — nothing is cached, nothing to delete
t2  the load returns D and inserts it
```

D would then be cached for a full TTL after deletion, with refresh-ahead renewing
it. So **any write to a key invalidates an in-flight load for that key**: the
result is discarded, the answer comes from current cache state, and
`[:smolsqls, :read_model, :load_discarded]` fires. `truncate` and `flush`
invalidate every in-flight load for the table and for all tables respectively.

This is covered two ways: an explicit interleaving matrix in
`Smolsqls.ReadModelTest` (delete before the load, mid-load, after the insert;
write-through mid-load; truncate mid-load; multi-waiter), and
`Smolsqls.ReadModelSoakTest`, which runs concurrent readers against a mutating
store and asserts the cache never holds a row the store dropped. Both were
validated by disabling the invalidation and confirming they fail.

## Expiry, eviction, and staleness

A sweeper runs every `sweep_interval_ms`:

- entries older than `ttl_ms` expire; negative entries expire on the shorter
  `negative_ttl_ms`
- over `max_entries`, eviction takes negative entries first (cheap to rebuild,
  and it keeps token spray from pushing out real rows), then the
  least-recently-loaded rows. Refresh-ahead keeps live entries young, so
  least-recently-loaded approximates LRU without a write on read. Victims come
  from a bounded top-k fold, so a cap breach costs `O(n log k)` time and `O(k)`
  memory rather than a sorted copy of the table
- **expiry pauses while the metadb is unreachable**, so a hot entry goes stale
  rather than vanishing mid-incident. Eviction keeps running — memory safety
  outranks staleness

Reachability is learned from load outcomes, plus a cheap `SELECT` probe each
sweep so a node with no traffic still notices the metadb coming back.

## What survives a metadb outage

| | metadb up | metadb down |
|---|---|---|
| query, database used in the last 24h | ✅ | ✅ served from cache; failed refreshes ignored, expiry paused |
| query, cold database | ✅ (one extra read) | ❌ retryable 503 `metadb_unavailable` |
| any query, first request after a deploy | ✅ | ❌ the cache starts empty |
| management auth | ✅ (cached) | ✅ resolves, but see below |
| management API, dashboard | ✅ | ❌ the endpoint's own queries hit Postgres |

**A miss during an outage is a retryable 503, never a 401.** A transient outage
must not read to a client as a revoked token, so `{:error, :metadb_unavailable}`
is kept distinct from `{:error, :unauthorized}` all the way out to the edge (see
`SmolsqlsWeb.Api.ErrorCode`). The same rule applies to limits: an unknown tenant
fails retryably rather than silently falling back to cluster defaults, because
defaulting would *raise* a database's effective `max_size_bytes`.

Accepted: a deploy empties the cache, so deploying during a metadb outage takes
queries down fleet-wide until Postgres returns. Persisting the tables across
restarts was considered and rejected as mechanism not worth its weight.

## The feed

`ReadModel.Replication` streams the metadb WAL over a permanent per-node logical
slot (`Postgrex.ReplicationConnection` plus a minimal pgoutput decoder), so LSN
continuity survives reconnects. On Postgres 15+ the publication excludes the
credential ciphertexts by column list, so a secret never enters the replication
stream; below 15 (no column lists) they are published and dropped on apply
instead. Both credential tables use `REPLICA IDENTITY USING INDEX
<table>_token_hash_index` so a delete event carries the cache key — otherwise
every node would need an id-to-hash index just to apply a revocation.

If Postgres reports the slot missing or invalidated, the WAL it needed is gone
and deletes have been lost, so the cache is **flushed** and the slot recreated.
Flushing rather than re-snapshotting is the payoff of a cache: correctness costs
one drop, and the read-through path refills whatever is still in use.

## Configuration

```elixir
config :smolsqls, Smolsqls.ReadModel,
  enabled: true,
  ttl_ms: :timer.hours(24),
  negative_ttl_ms: :timer.seconds(30),
  max_entries: 250_000
```

Also available: `refresh_ratio` (default `0.5`), `refresh_jitter_ms`,
`sweep_interval_ms`, `evict_hysteresis`, `load_timeout_ms`. With `enabled: false`
(the test default) reads go straight to Postgres through `ReadModel.Source`.

## Operating it

Metrics are on `GET /metrics`; alert conditions live in
[`docs/alerts.md`](alerts.md). The two that matter:

- `smolsqls_read_model_counters_misses` — every miss is a metadb read. A spike
  means a deploy refilling caches, an eviction storm (check
  `counters_evicted`), or token spray.
- `smolsqls_read_model_health_stale` — `1` while this node cannot reach the
  metadb, which is also when expiry is paused and cold databases are getting
  503s.

Also exported: per-table `entries` and `memory_bytes`, `hits`, `negative_hits`,
`refreshes`, `collapsed` (reads that avoided a redundant query), `discarded`
(loads thrown away because the key was mutated mid-flight), `load_timeouts`,
`load_failures`, `expired`, `evicted`, and `health_inflight`.
