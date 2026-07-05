# sqlites

A multitenant, globally clusterable SQLite database service written in
Elixir/Phoenix. Sign up for a tenant, create SQLite databases over a REST
API (or a small LiveView UI), get a connection string back, and connect
with any stock libSQL client or plain HTTP.

## Architecture

Built for ~1M databases per cluster across ~10 data-plane nodes.

**Control plane** (Postgres-backed): tenants, databases, auth tokens, and
placement decisions. Postgres is the source of truth for writes but never
sits on the query path: every node keeps a **full ETS replica** of the
request-path tables, bootstrapped with `COPY` at startup and kept current
by streaming the WAL over a per-node permanent logical replication slot
(`Postgrex.ReplicationConnection` + a minimal pgoutput decoder). Postgres
downtime pauses create/delete; queries and auth keep working.

**Data plane**: one `Sqlites.DataPlane.Database.Server` GenServer per
database owns the single `exqlite` connection to that SQLite file (WAL
mode) and serializes all writes. Servers activate **lazily on first
query** and stay hot for a configurable idle TTL (default 1h), so boot is
cold and traffic warms the set. Processes register in
[`syn`](https://hex.pm/packages/syn) under the `:sqlites_databases`
scope, so every node knows which node owns which database; registration
happens before the SQLite file is opened, which guarantees a single
writer even under racing activations. Cross-node query traffic travels
over [`gen_rpc`](https://hex.pm/packages/gen_rpc) — Erlang distribution
carries only cluster membership, syn gossip, and
[libcluster_postgres](https://github.com/supabase/libcluster_postgres)
node discovery (LISTEN/NOTIFY on the metadb), never query payloads.
On boot each node walks its data volume and claims any database whose
file is local but whose record points elsewhere — the volume, not the
node name, is the source of truth for placement.

**Storage portability**: S3 is the source of truth for cold databases;
node volumes are caches. When a database server idle-stops, it ships a
`VACUUM INTO` snapshot to
`idle-snapshots/<tenant>/<db>/latest.db` and bumps a
`snapshot_generation` in the metadb. (Every session ships — skipping
the upload for read-only sessions is deferred until statements can be
classified by a real SQL parser rather than heuristics.) Activation
trusts placement + generation, never bare file
presence: a cached file whose `<file>.generation` sidecar is behind
the metadb is discarded and re-fetched, and a missing file restores
via litestream replica (premium) → idle snapshot → latest manual
backup. This makes placement free: draining a node is metadata-only
for anything already shipped (`Sqlites.Drain`, driven by the operator
through the `node_drains` metadb table), and an optional LRU cache
evictor (`CACHE_EVICTION_ENABLED` / `CACHE_HIGH_WATER_BYTES`) keeps
volumes under a high-water mark by deleting cold, provably-shipped
files.

**Client access** — no custom client needed:

- **libSQL / Hrana**: any stock libSQL client (`@libsql/client`, etc.)
  connects with the `libsql://host:port?authToken=...` string returned
  at creation time. The server speaks a Hrana v1/v2 subset over
  WebSocket (`execute`, `batch`, `store_sql`, `named_args`,
  `describe`, `sequence`); the auth token identifies the database.
  Interactive transactions (`BEGIN`) are rejected cleanly — statements
  run in autocommit mode.
- **Hrana over HTTP**: `POST /v2/pipeline` (stateless, batons
  unsupported) for `http://` libsql URLs and edge runtimes.
- **Plain HTTP**: `POST /v1/databases/:id/query` with
  `{"sql": "...", "args": [...]}` and the database auth token as a
  Bearer token.

**Quotas & limits** are rows, not config: a `limits` map on `tenants`
with per-database overrides on `databases`, falling back to cluster
defaults (`config :sqlites, Sqlites.Limits`). Resolution is
database → tenant → default, served from the read model. The set:
`max_databases` (create time), `max_size_bytes`
(`PRAGMA max_page_count` at activation), `rate_limit_rps` (per-node
fixed window at the protocol edge), `query_timeout_ms`,
`statement_timeout_ms` (server-side `sqlite3_interrupt` of runaway
statements), `idle_ttl_ms`, and `max_hot_ms`. Resolved limits are
exposed read-only on the database/tenant show endpoints; there is no
public mutation path yet.

**Token lifecycle**: credentials are managed rows, not columns on the
owner. A database holds any number of permanent tokens
(`/v1/databases/:id/tokens`) and a tenant any number of API keys
(`/v1/tenant/keys`) — create (optionally with `expires_at`),
enable/disable (`PATCH {enabled: false}`), and delete, each
independently; revocation propagates immediately through the read
model. Creating a database or tenant creates a `default` secret and
returns it. At rest a secret is a SHA-256 hash (the auth lookup key)
plus an AES-256-GCM ciphertext (`TOKEN_ENCRYPTION_KEY`, falling back
to `SECRET_KEY_BASE`) — never plaintext, never logged. Secrets appear
only in create responses and explicit `POST .../reveal` calls, which
is also how the dashboard shows connection strings. The last usable
tenant key cannot be disabled or deleted. List endpoints
cursor-paginate with `?after=<id>&limit=<n>` and return a `next`
cursor.

**Durability** is an infrastructure concern owned by the Kubernetes
operator in [`operator/`](operator/): PVC-backed data directories,
Litestream replication, and CRD-driven backup/restore. The control plane
talks to it exclusively through the `Sqlites.Infra` port by manipulating
`SqliteDatabase` custom resources (`Sqlites.Infra.Kubernetes`); dev and
test use `Sqlites.Infra.Local` (backups via `VACUUM INTO`).

## Agent-friendly by design

The full lifecycle is drivable over HTTP with no human steps:

```sh
# discover the API
curl http://localhost:4000/v1

# sign up (api_key returned once)
curl -X POST http://localhost:4000/v1/tenants \
  -H 'content-type: application/json' \
  -d '{"name": "My Org", "slug": "my-org"}'

# create a database (returns auth_token + connection strings)
curl -X POST http://localhost:4000/v1/databases \
  -H "authorization: Bearer $API_KEY" \
  -H 'content-type: application/json' \
  -d '{"name": "task-db"}'

# query it
curl -X POST http://localhost:4000/v1/databases/$DB_ID/query \
  -H "authorization: Bearer $DB_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"sql": "SELECT 1"}'

# trigger / list backups, restore
curl -X POST http://localhost:4000/v1/databases/$DB_ID/backups \
  -H "authorization: Bearer $API_KEY"
curl -X POST http://localhost:4000/v1/databases/$DB_ID/restore \
  -H "authorization: Bearer $API_KEY" \
  -H 'content-type: application/json' \
  -d "{\"backup_id\": \"$BACKUP_ID\"}"
```

Or with a stock libSQL client:

```js
import { createClient } from "@libsql/client";

const client = createClient({
  url: "ws://localhost:4000",
  authToken: process.env.DB_TOKEN,
});
await client.execute("SELECT 1");
```

## Running locally

Requires Erlang/OTP 27+, Elixir 1.18+, and Postgres on `localhost:5432`
(`postgres`/`postgres`).

```sh
mix setup
iex --sname sqlites -S mix phx.server
```

The LiveView UI is at [`localhost:4000`](http://localhost:4000) — sign
up or paste a tenant API key, then create/delete databases, reveal
connection strings, and trigger backups from the dashboard.

## Deploying (Kubernetes)

`deploy/` holds kustomize manifests: a 3-replica StatefulSet where pod
`sqlites-N` ↔ PVC `data-sqlites-N` ↔ Erlang node name (the volume-claim
identity model), each pod running a Litestream sidecar that databases
are registered with dynamically over a control socket. The
[operator](operator/) tracks one `SqliteNode` CR per data-plane node —
never per database — reporting replication-slot health and database
counts onto `kubectl get sqlitenodes`. Setting `spec.drain: true`
inserts a request into the metadb's `node_drains` table; the data
plane's drain worker claims it, idle-stops hot databases (shipping
their snapshots), reassigns placement rows to the survivors, and the
operator reports progress on `status.drain`. Re-draining a node
requires deleting its `node_drains` row.

Local end-to-end cluster (kind + in-cluster Postgres with
`wal_level=logical` + MinIO):

```sh
./scripts/kind-up.sh
curl http://localhost:8080/v1
```

## Tests

```sh
mix test                        # unit + integration (needs Postgres)
mix test --include distributed  # + multi-node syn/gen_rpc tests (needs epmd)
```

The distributed tests boot a real peer BEAM node with `:peer`, place a
database server on it, and assert that syn resolves it from the primary
node and that queries round-trip over gen_rpc (on a distinct TCP port),
including deregistration when the peer dies.

## Repo layout

```
lib/sqlites/control_plane*    # tenants, databases, placement metadata (Ecto/Postgres)
lib/sqlites/data_plane*       # per-database servers, syn registry, gen_rpc router
lib/sqlites/infra*            # port to the durability layer (Local / Kubernetes adapters)
lib/sqlites_web/controllers/  # REST API (see GET /v1 for the index)
lib/sqlites_web/hrana/        # Hrana (libSQL) WebSocket endpoint
lib/sqlites_web/live/         # LiveView dashboard
operator/                     # Bonny-based Kubernetes operator (SqliteDatabase CRD)
```
