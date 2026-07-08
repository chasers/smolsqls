# smolsqls

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

**Data plane**: one `Smolsqls.DataPlane.Database.Server` GenServer per
database owns the single `exqlite` connection to that SQLite file (WAL
mode) and serializes all writes. Servers activate **lazily on first
query** and stay hot for a configurable idle TTL (default 1h), so boot is
cold and traffic warms the set. Processes register in
[`syn`](https://hex.pm/packages/syn) under the `:smolsqls_databases`
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
classified by a real SQL parser rather than heuristics.) Objects are
stored gzip-compressed, transparently and streaming in both directions
(the S3 adapter compresses on ship and decompresses on restore, so
callers only see logical files and memory stays bounded regardless of
database size); reads fall back to raw for objects written before
compression. Activation
trusts placement + generation, never bare file
presence: a cached file whose `<file>.generation` sidecar is behind
the metadb is discarded and re-fetched, and a missing file restores
via litestream replica (premium) → idle snapshot → latest manual
backup. This makes placement free: draining a node is metadata-only
for anything already shipped (`Smolsqls.Drain`, driven by the operator
through the `node_drains` metadb table), and an optional LRU cache
evictor (`CACHE_EVICTION_ENABLED` / `CACHE_HIGH_WATER_BYTES`) keeps
volumes under a high-water mark by deleting cold, provably-shipped
files.

**Daily backups**: every database is guaranteed at least one backup a
day. A cluster-singleton sweeper (`Smolsqls.Backups.Sweeper`, one node
at a time via a Postgres advisory lock) finds databases whose newest
backup is older than 24h and produces an `automatic` backup for each —
promoting the existing idle snapshot with a server-side object-store
copy for a cold database (no activation) and snapshotting the live
writer for a hot one. These appear in the backups list alongside
`manual` backups. This is a daily *artifact* floor, not point-in-time
recovery; continuous durability for premium databases is litestream's
job.

**Client access** — no custom client needed:

- **libSQL / Hrana**: any stock libSQL client (`@libsql/client`, etc.)
  connects with the `libsql://host:port?authToken=...` string returned
  at creation time. The server speaks a Hrana v1/v2 subset over
  WebSocket (`execute`, `batch`, `store_sql`, `named_args`,
  `describe`, `sequence`); the auth token identifies the database.
  Interactive transactions work on this transport: `BEGIN` takes a
  writer lease owned by the connection, bounded by the
  `txn_timeout_ms` limit and auto-rolled-back on disconnect; other
  connections fail fast with a busy error until it ends.
- **Hrana over HTTP**: `POST /v2/pipeline` and `POST /v3/pipeline`
  (with `GET /v2` / `GET /v3` version probes) for `http://` / `https://`
  libsql URLs, edge runtimes, and browser clients. Transactions work
  within a single pipeline request — `BEGIN`/`COMMIT`/`ROLLBACK` and the
  conditional batches libSQL clients emit run against one connection and
  any transaction left open is rolled back at request end — but do not
  persist across requests (batons unsupported). CORS is open (`*`) on
  the token-authenticated API (bearer auth, no cookies), so browser
  clients such as LibSQL Studio connect directly.
- **Plain HTTP**: `POST /v1/databases/:id/query` with
  `{"sql": "...", "args": [...]}` and the database auth token as a
  Bearer token.

**Tenant SQL is sandboxed** on the shared per-database connection. Every
tenant statement runs under a SQLite authorizer that denies `ATTACH`,
`DETACH`, and therefore `VACUUM` — closing cross-tenant and arbitrary
host-file access (and `VACUUM INTO` writes). Native extension loading is
explicitly disabled (`load_extension(...)` is rejected). The authorizer is
scoped to tenant statements only; privileged snapshots (backups, idle ships)
run `VACUUM INTO` through a separate unauthorized path
(`Server.snapshot_into/3`). Two residual gaps remain, both confined to the
tenant's own database (not cross-tenant escapes): tenant
`PRAGMA max_page_count` (size-cap evasion for the hot session) and
`PRAGMA writable_schema` (schema self-corruption). Robustly closing them needs
`SQLITE_DBCONFIG_DEFENSIVE`/`SQLITE_LIMIT`, which exqlite's API does not yet
expose.

**Quotas & limits** are rows, not config: a `limits` map on `tenants`
with per-database overrides on `databases`, falling back to cluster
defaults (`config :smolsqls, Smolsqls.Limits`). Resolution is
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

**Unattended failover**: the operator watches each node's pod
readiness and metadb replication-slot activity; when both say a node
is gone for longer than `AUTO_EVACUATE_WINDOW_SECONDS`, it inserts an
`evacuate` request on the same `node_drains` bus that drains use, and
the data plane reassigns the dead node's placement rows to survivors
(cancelled at claim time if the node reconnected). A returning node
is fenced: servers still running for re-placed databases are stopped
without shipping. Inter-node traffic can run over TLS (`GEN_RPC_TLS`
for query traffic, `DIST_TLS` for membership; per-node certs, see
`scripts/gen-dev-certs.sh`). Each node exposes Prometheus metrics at
`GET /metrics` (cluster-internal; alert conditions in
[`docs/alerts.md`](docs/alerts.md)).

**Durability** is an infrastructure concern owned by the Kubernetes
operator in [`operator/`](operator/): PVC-backed data directories,
Litestream replication, and CRD-driven backup/restore. The control plane
talks to it exclusively through the `Smolsqls.Infra` port by manipulating
`SqliteDatabase` custom resources (`Smolsqls.Infra.Kubernetes`); dev and
test use `Smolsqls.Infra.Local` (backups via `VACUUM INTO`).

## Agent-friendly by design

The full lifecycle is drivable over HTTP with no human steps. Every
successful response is a JSON object `{"data": <object>}` (list
endpoints add a top-level `next` cursor); errors are
`{"error": {"code", "message"}}`. Secrets and connection strings
(`api_key`, `auth_token`, `connections`) come back only in the create
response and are never echoed by later reads — `GET /v1` documents the
full contract.

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

# branch it into a new, independent database seeded from its latest snapshot
# (returns the new database + its auth_token, like create)
curl -X POST http://localhost:4000/v1/databases/$DB_ID/branch \
  -H "authorization: Bearer $API_KEY" \
  -H 'content-type: application/json' \
  -d '{"name": "task-db-branch"}'
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

Requires Erlang/OTP 27+, Elixir 1.20+, and Postgres on `localhost:5432`
(`postgres`/`postgres`).

```sh
mix setup
iex --sname smolsqls -S mix phx.server
```

The LiveView UI is at [`localhost:4000`](http://localhost:4000) — sign
up or paste a tenant API key, then create/delete databases, reveal
connection strings alongside ready-to-run curl and `@libsql/client`
quickstart snippets, and trigger backups from the dashboard. The
**API keys** page (`/account`) manages account-level tenant keys:
create any number (optionally named), reveal, copy, enable/disable, and
delete — new signups land here to copy their first key.

## Deploying (Kubernetes)

`deploy/` holds kustomize manifests: a 3-replica StatefulSet where pod
`smolsqls-N` ↔ PVC `data-smolsqls-N` ↔ Erlang node name (the volume-claim
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

`kubectl` here is scoped to the local `kind-smolsqls` cluster via
[direnv](https://direnv.net): `.envrc` exports `KUBECONFIG=$PWD/.kube/config`, a
gitignored single-context kubeconfig (run `direnv allow` once). Regenerate it
with `mkdir -p .kube && kubectl config view --minify --flatten --context
kind-smolsqls > .kube/config`.

The `FORCE_SSL` Docker build arg (default `true`) gates the compile-time
`force_ssl` redirect; build with `--build-arg FORCE_SSL=false` when the
endpoint sits behind a plain-HTTP load balancer. A full GCP/GKE deployment
(Terraform + kustomize overlay for Cloud SQL, GCS, and Artifact Registry)
lives in the sibling `smolsqls-deploy` repo.

## Tests

```sh
mix test                        # unit + integration (needs Postgres)
mix test --include distributed  # + multi-node syn/gen_rpc tests (needs epmd)
```

The distributed tests boot a real peer BEAM node with `:peer`, place a
database server on it, and assert that syn resolves it from the primary
node and that queries round-trip over gen_rpc (on a distinct TCP port),
including deregistration when the peer dies.

## Quality gate

```sh
mix precommit  # mutating: compile -Werror, format, credo --strict, test
mix ci         # non-mutating superset CI runs (no DB needed)
```

`mix ci` is the merge gate: `hex.audit` (dependency CVEs) → compile
(warnings-as-errors) → `deps.unlock --check-unused` → `format
--check-formatted` → `credo --strict` (with the [ExSlop](https://github.com/elixir-vibe/ex_slop)
plugin's AI-slop checks) → `deps.audit` → `sobelow` (security scan,
`.sobelow-conf` holds accepted skips) → `reach.check --arch`
([Reach](https://github.com/elixir-vibe/reach) layer policy in `.reach.exs`:
the data/control/read planes must not depend on the web layer). CI runs it as
a fast, Postgres-free `checks` job in parallel with the test jobs; the
`operator/` subproject has its own `mix ci` and test job.

Two more checks run in their own CI jobs (not in `mix ci`, so the fast gate
stays fast):

```sh
mix dialyzer   # type analysis; PLT cached in CI on {OTP, Elixir, mix.lock}
mix ex_dna     # duplication report ([ExDNA](https://github.com/elixir-vibe/ex_dna), advisory)
```

Dialyzer gates (ignore file: `.dialyzer_ignore.exs`); ExDNA is advisory for now
(`.ex_dna.exs`), to be ratcheted to a `--max-clones` budget once its count is
stable. See `.github/workflows/ci.yml`.

## Repo layout

```
lib/smolsqls/control_plane*    # tenants, databases, placement metadata (Ecto/Postgres)
lib/smolsqls/data_plane*       # per-database servers, syn registry, gen_rpc router
lib/smolsqls/infra*            # port to the durability layer (Local / Kubernetes adapters)
lib/smolsqls_web/controllers/  # REST API (see GET /v1 for the index)
lib/smolsqls_web/hrana/        # Hrana (libSQL) WebSocket endpoint
lib/smolsqls_web/live/         # LiveView dashboard
operator/                     # Bonny-based Kubernetes operator (SqliteDatabase CRD)
bench/                        # performance harnesses + RESULTS.md (qps, cold_start, litestream_density, schedulers)
skills/                       # Claude Code skills (run skills/install.sh to link them in; see skills/README.md)
```

Benchmarks live under `bench/<area>/` with a `RESULTS.md` per area. The
query-path ones run locally via `mix run bench/<area>/*.exs`; the cluster
ones (`bench/qps/kind_latency.sh`, `bench/cold_start/run.sh`) `kubectl exec`
into a pod to measure against the real MinIO/S3 store and cross-pod topology.
