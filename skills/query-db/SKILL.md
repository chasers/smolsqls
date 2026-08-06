---
name: query-db
description: >-
  The shared Elixir tools for talking to ANY smolsqls database over HTTP:
  querying (POST /v1/databases/:id/query) and subscribing to the SSE change
  feed (GET /v1/databases/:id/changes). This is the low-level primitive the
  query-alpha-db and smolsqls-pm skills build on. Use it directly to run SQL
  against an arbitrary smolsqls database given its URL / id / auth_token, to
  watch its change stream, or when you need the CLI mechanics (positional args,
  --args-file, applying a .sql file, JSON output, reconnecting subscriptions).
  Triggers on: "query a smolsqls db", "run SQL against a smolsqls database",
  "use the query tool", "subscribe to the change feed", "watch changes on a db".
---

# query-db — the smolsqls query tool

`smolsqls_query.exs` is a self-contained Elixir CLI that POSTs to a smolsqls
database's HTTP query endpoint. It's an Elixir project, so we query it in Elixir,
not curl. `Mix.install` pulls Req on first run — no project compile, works from
the repo or a globally-symlinked skill. Needs `elixir` on `PATH`.

```sh
elixir skills/query-db/smolsqls_query.exs [opts] "SQL [...]"
elixir skills/query-db/smolsqls_query.exs [opts] --file path/to/schema.sql
```

## Options

| Option | Meaning |
|---|---|
| `--db NAME` | credential set (default `pm`); any name works |
| `--url URL` | base URL override (non-secret) |
| `--id ID` | database id override (non-secret) |
| `--env FILE` | dotenv file to load first (default: per `--db`) |
| `--args JSON` | positional args bound to `?`, e.g. `--args '["x",1]'` |
| `--args-file FILE` | read the JSON args array from a file (large values, e.g. a markdown body) |
| `--file FILE` | apply each `;`-separated statement in FILE (schema/migration) |
| `--json` | print the raw JSON response instead of an aligned table |

## Credentials — from the environment, never on argv

For `--db NAME`, the tool reads `SMOLSQLS_<NAME>_URL` / `_DB_ID` / `_DB_TOKEN`
(NAME upper-cased, non-alphanumerics → `_`) and auto-loads a git-ignored dotenv
file if present:

| `--db` | env prefix | default env file |
|---|---|---|
| `pm` | `SMOLSQLS_PM_*` | `.claude/smolsqls-pm.env` |
| `alpha` | `SMOLSQLS_ALPHA_*` | `.claude/alpha-db.env` |
| `<x>` | `SMOLSQLS_<X>_*` | `.claude/<x>.env` |

`--url` and `--id` may be passed explicitly (they aren't secret). The
**`auth_token` is only ever read from the environment** — never accept it on the
command line. URL defaults to `https://alpha.smolsqls.com`.

## Output & errors

- Default: an aligned text table; writes print `ok (num_changes: N)`.
- `--json`: the raw success body `{"data": {"columns", "rows", "num_changes"}}`.
- On an API error the tool prints `error: <code>: <message>` to stderr and exits
  non-zero.

## Server-side rules (apply to every caller)

- **One statement per query.** The endpoint runs a single statement and rejects
  transaction control (`BEGIN`/`COMMIT`/`ROLLBACK`) → `transactions_not_supported`.
- **`ATTACH` / `DETACH` / `VACUUM`** are denied for tenant SQL → `authorization
  denied`.
- Bind values with `?` placeholders + `--args`/`--args-file` — never
  string-interpolate.

## Subscribing to the change feed

`smolsqls_subscribe.exs` streams a database's SSE change feed
(`GET /v1/databases/:id/changes`, same per-database Bearer token). Same
credential model as the query tool. It prints one JSON object per change to
stdout (jsonl) and reconnects automatically, so run it as a background process
and kill it when done:

```sh
elixir skills/query-db/smolsqls_subscribe.exs --db alpha            # stream forever
elixir skills/query-db/smolsqls_subscribe.exs --db alpha --max-events 5   # exit after 5 (tests)
elixir skills/query-db/smolsqls_subscribe.exs --db alpha --once     # one connection, no reconnect
```

Events look like
`{"table":"items","record":{...},"action":"insert","rowid":1}` with `action`
one of `insert` / `update` / `delete`. Connection lifecycle goes to stderr.

Contract & gotchas (also apply to hand-rolled clients):

- Auth is the **database `auth_token`** (Bearer), like the query endpoint.
  Requires `change_stream_enabled` on the database (default on) →
  else `403 change_stream_disabled`.
- `?timeout_ms=` caps each connection **server-side** (default 5 min, max 10
  min) — every client must reconnect when a stream ends; the tool does this
  with a 1s backoff.
- **No resume cursor yet**: events between connections are lost (frames carry
  no `id:`, the endpoint takes no `Last-Event-ID`). Don't build sync on this
  until that lands — it's a live tail, not a log.
- **Never send `accept: text/event-stream`** — the endpoint 406s on it. curl's
  default `*/*` works: `curl -N .../changes?timeout_ms=600000 -H
  "authorization: Bearer $TOKEN"`.
- The server writes a `: keepalive` comment every 15s; the tool drops and
  redials a connection silent for 60s.

## Built on this

- **`query-alpha-db`** — ad-hoc queries against alpha (`--db alpha`).
- **`smolsqls-pm`** — the project tracker (`--db pm`), with a schema and
  project/plan/task operations.
