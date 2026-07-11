# Architecture

How smolsqls works under the hood. The [README](../README.md) gives the
one-screen version; this is the deep dive.

Built for ~1M databases per cluster across ~10 data-plane nodes.

## Control plane

Postgres-backed: tenants, databases, auth tokens, and placement decisions.
Postgres is the source of truth for writes but never sits on the query path:
every node keeps a **full ETS replica** of the request-path tables, bootstrapped
with `COPY` at startup and kept current by streaming the WAL over a per-node
permanent logical replication slot (`Postgrex.ReplicationConnection` + a minimal
pgoutput decoder). Postgres downtime pauses create/delete; queries and auth keep
working.

## Data plane

One `Smolsqls.DataPlane.Database.Server` GenServer per database owns the single
`exqlite` connection to that SQLite file (WAL mode) and serializes all writes.
Servers activate **lazily on first query** and stay hot for a configurable idle
TTL (default 1h), so boot is cold and traffic warms the set. Processes register
in [`syn`](https://hex.pm/packages/syn) under the `:smolsqls_databases` scope, so
every node knows which node owns which database; registration happens before the
SQLite file is opened, which guarantees a single writer even under racing
activations. Cross-node query traffic travels over
[`gen_rpc`](https://hex.pm/packages/gen_rpc) — Erlang distribution carries only
cluster membership, syn gossip, and
[libcluster_postgres](https://github.com/supabase/libcluster_postgres) node
discovery (LISTEN/NOTIFY on the metadb), never query payloads. On boot each node
walks its data volume and claims any database whose file is local but whose
record points elsewhere — the volume, not the node name, is the source of truth
for placement.

## Storage portability

S3 is the source of truth for cold databases; node volumes are caches. When a
database server idle-stops, it ships a `VACUUM INTO` snapshot to
`idle-snapshots/<tenant>/<db>/latest.db` and bumps a `snapshot_generation` in the
metadb. (Every session ships — skipping the upload for read-only sessions is
deferred until statements can be classified by a real SQL parser rather than
heuristics.) Objects are stored gzip-compressed, transparently and streaming in
both directions (the S3 adapter compresses on ship and decompresses on restore,
so callers only see logical files and memory stays bounded regardless of database
size); reads fall back to raw for objects written before compression. Activation
trusts placement + generation, never bare file presence: a cached file whose
`<file>.generation` sidecar is behind the metadb is discarded and re-fetched, and
a missing file restores via litestream replica (premium) → idle snapshot → latest
manual backup. This makes placement free: draining a node is metadata-only for
anything already shipped (`Smolsqls.Drain`, driven by the operator through the
`node_drains` metadb table), and an optional LRU cache evictor
(`CACHE_EVICTION_ENABLED` / `CACHE_HIGH_WATER_BYTES`) keeps volumes under a
high-water mark by deleting cold, provably-shipped files.

## Daily backups

Every database is guaranteed at least one backup a day. A cluster-singleton
sweeper (`Smolsqls.Backups.Sweeper`, one node at a time via a Postgres advisory
lock) finds databases whose newest backup is older than 24h and produces an
`automatic` backup for each — promoting the existing idle snapshot with a
server-side object-store copy for a cold database (no activation) and
snapshotting the live writer for a hot one. These appear in the backups list
alongside `manual` backups. This is a daily *artifact* floor, not point-in-time
recovery; continuous durability for premium databases is litestream's job. Any
backup can be **downloaded** as a plain SQLite file —
`GET /v1/databases/:id/backups/:backup_id/download` (tenant api_key) or the
dashboard's Download action — served straight from the object store (gunzipped),
so no restore is needed to inspect one locally.

## Branching

Fork any database into a new, independent one —
`POST /v1/databases/:id/branch` or the dashboard's Branch action. A branch is a
*physical copy*, not copy-on-write (every database is its own SQLite file), seeded
**without touching the parent's writer** — bytes come from the object store, never
the live connection. The source is either a **snapshot** (the parent's latest idle
snapshot or a backup, server-side copied to the child's key — available to any
database) or, for litestream-enabled databases, an exact **point in time** within
the recoverable window (litestream restore to a `timestamp`; 30 days, backed by
`LITESTREAM_RETENTION`). The child records its lineage (`source_database_id`,
`branch_point_at`), gets its own default token, counts against the tenant's
database limit (a branch *is* a database), and starts un-replicated by default.
Branches can be **ephemeral**: set `expires_at` and a cluster-singleton sweeper
(`Smolsqls.ExpirySweeper`) reaps them once past. A database with branches can't be
deleted until its branches are gone (no cascade); the dashboard nests branches
under their parent with a count.

## Regions

A database has a **primary region** — where its file lives and its writer runs —
chosen at create time (`{"region": "gcp-us-central1"}`, defaulting to
`DEFAULT_REGION`) and validated against the cluster's configured set (`REGIONS`).
A region slug is a single hyphenated DNS label combining hosting provider and
provider-native region (`gcp-us-central1`, `aws-us-east-1`); the provider is
stored alongside as `cloud`. Placement constrains a database's owner to a live
node in its region — each node publishes its own region to a `nodes` table on boot
(`REGION`) — and rejects a create with `no_capacity_in_region` rather than
silently placing it elsewhere. Branches inherit their source's region. The region
system is dormant when `REGIONS` is empty (dev, single-cluster): databases carry
no region and placement stays purely load-based.

**Moving a database** to another region is a `PATCH /v1/databases/:id` with a new
`region` (or the dashboard's Move action). The move ships the current state to the
object store, marks the database `:moving` — a fence that makes every converged
node refuse to activate its writer, so a stale read model can't revive it in the
old region — then reassigns its placement to a node in the target region, which
restores lazily. Queries racing the move get a retryable `database_relocating`
(503). The fence is only as timely as the read model: the handling node updates
synchronously, other region nodes converge over the WAL feed, so a query on a
not-yet-converged node can still briefly reach the old owner (bounded by
replication lag) — the same eventual-consistency window drains live with.
Connection strings return a **global** host (`PHX_HOST`, e.g.
`alpha.daisy.smolsqls.com`) that a global load balancer geo-routes to the nearest
region — any node transparently proxies a query to the owner — plus a **regional**
host that splices the region slug in as the second label
(`alpha.gcp-us-central1.daisy.smolsqls.com`) to pin traffic to the owning region
for debugging. (Multi-region deployment — per-region clusters, the global load
balancer, and cross-region clustering — is in progress; the application,
placement, and connection-string layers land first.)

## Client transports

No custom client needed:

- **libSQL / Hrana**: any stock libSQL client (`@libsql/client`, etc.) connects
  with the `libsql://host:port?authToken=...` string returned at creation time.
  The server speaks a Hrana v1/v2 subset over WebSocket (`execute`, `batch`,
  `store_sql`, `named_args`, `describe`, `sequence`); the auth token identifies
  the database. Interactive transactions work on this transport: `BEGIN` takes a
  writer lease owned by the connection, bounded by the `txn_timeout_ms` limit and
  auto-rolled-back on disconnect; other connections fail fast with a busy error
  until it ends.
- **Hrana over HTTP**: `POST /v2/pipeline` and `POST /v3/pipeline` (with
  `GET /v2` / `GET /v3` version probes) for `http://` / `https://` libsql URLs,
  edge runtimes, and browser clients. Transactions work within a single pipeline
  request — `BEGIN`/`COMMIT`/`ROLLBACK` and the conditional batches libSQL clients
  emit run against one connection and any transaction left open is rolled back at
  request end — but do not persist across requests (batons unsupported). CORS is
  open (`*`) on the token-authenticated API (bearer auth, no cookies), so browser
  clients such as LibSQL Studio connect directly.
- **Plain HTTP**: `POST /v1/databases/:id/query` with
  `{"sql": "...", "args": [...]}` and the database auth token as a Bearer token.

## Tenant SQL sandbox

Tenant SQL is sandboxed on the shared per-database connection. Every tenant
statement runs under a SQLite authorizer that denies `ATTACH`, `DETACH`, and
therefore `VACUUM` — closing cross-tenant and arbitrary host-file access (and
`VACUUM INTO` writes). Native extension loading is explicitly disabled
(`load_extension(...)` is rejected). The authorizer is scoped to tenant statements
only; privileged snapshots (backups, idle ships) run `VACUUM INTO` through a
separate unauthorized path (`Server.snapshot_into/3`). Two residual gaps remain,
both confined to the tenant's own database (not cross-tenant escapes): tenant
`PRAGMA max_page_count` (size-cap evasion for the hot session) and
`PRAGMA writable_schema` (schema self-corruption). Robustly closing them needs
`SQLITE_DBCONFIG_DEFENSIVE`/`SQLITE_LIMIT`, which exqlite's API does not yet
expose.

## Quotas & limits

Rows, not config: a `limits` map on `tenants` with per-database overrides on
`databases`, falling back to cluster defaults
(`config :smolsqls, Smolsqls.Limits`). Resolution is database → tenant → default,
served from the read model. The set: `max_databases` (create time),
`max_size_bytes` (`PRAGMA max_page_count` at activation), `rate_limit_rps`
(per-node fixed window at the protocol edge), `query_timeout_ms`,
`statement_timeout_ms` (server-side `sqlite3_interrupt` of runaway statements),
`idle_ttl_ms`, and `max_hot_ms`. Resolved limits are exposed read-only on the
database/tenant show endpoints; there is no public mutation path yet.

## Token lifecycle

Credentials are managed rows, not columns on the owner. A database holds any
number of permanent tokens (`/v1/databases/:id/tokens`) and a tenant any number of
API keys (`/v1/tenant/keys`) — create (optionally with `expires_at`),
enable/disable (`PATCH {enabled: false}`), and delete, each independently;
revocation propagates immediately through the read model. Creating a database or
tenant creates a `default` secret and returns it. At rest a secret is a SHA-256
hash (the auth lookup key) plus an AES-256-GCM ciphertext (`TOKEN_ENCRYPTION_KEY`,
falling back to `SECRET_KEY_BASE`) — never plaintext, never logged. Secrets appear
only in create responses and explicit `POST .../reveal` calls, which is also how
the dashboard shows connection strings. The last usable tenant key cannot be
disabled or deleted. List endpoints cursor-paginate with `?after=<id>&limit=<n>`
and return a `next` cursor.

## Unattended failover

The operator watches each node's pod readiness and metadb replication-slot
activity; when both say a node is gone for longer than
`AUTO_EVACUATE_WINDOW_SECONDS`, it inserts an `evacuate` request on the same
`node_drains` bus that drains use, and the data plane reassigns the dead node's
placement rows to survivors (cancelled at claim time if the node reconnected). A
returning node is fenced: servers still running for re-placed databases are
stopped without shipping. Inter-node traffic can run over TLS (`GEN_RPC_TLS` for
query traffic, `DIST_TLS` for membership; per-node certs, see
`scripts/gen-dev-certs.sh`). Each node exposes Prometheus metrics at `GET /metrics`
(cluster-internal; alert conditions in [`alerts.md`](alerts.md)).

## Durability

An infrastructure concern owned by the Kubernetes operator in
[`operator/`](../operator/): PVC-backed data directories, Litestream replication,
and CRD-driven backup/restore. The control plane talks to it exclusively through
the `Smolsqls.Infra` port by manipulating `SqliteDatabase` custom resources
(`Smolsqls.Infra.Kubernetes`); dev and test use `Smolsqls.Infra.Local` (backups
via `VACUUM INTO`).

## Error contract

Every successful response is a JSON object `{"data": <object>}` (list endpoints
add a top-level `next` cursor); errors are `{"error": {"code", "message"}}`, where
`code` is a stable textual class (e.g. `not_found`, `object_storage_put`) and 5xx
errors add a `request_id` for log correlation — raw internal detail is logged,
never returned ([full code list](api-errors.md)). Secrets and connection strings
(`api_key`, `auth_token`, `connections`) come back only in the create response and
are never echoed by later reads — `GET /v1` documents the full contract.
