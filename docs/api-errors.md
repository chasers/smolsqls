# API error codes

Every non-2xx API response is a JSON object:

```json
{"error": {"code": "<stable textual class>", "message": "<safe description>"}}
```

`code` is a **stable textual class** — safe to expose, safe to branch on in a
client. `message` is a generic, non-leaking description. Raw internal detail
(exception terms, upstream error bodies) is **never** returned; it is logged
server-side. `SmolsqlsWeb.Api.ErrorCode` is the single source of truth for this
mapping; the Hrana/libSQL path surfaces the same classification.

**Server errors (5xx) also include a `request_id`:**

```json
{"error": {"code": "object_storage_put", "message": "object storage operation failed", "request_id": "F1a2b3..."}}
```

Quote that `request_id` to correlate with the server logs, which record the full
reason at `error` level (`api error code=<code> request_id=<id> reason=<term>`).

## Client errors (4xx)

Caused by the request; safe to surface to the end user. No `request_id`.

| Code | HTTP | Meaning |
| --- | --- | --- |
| `validation_failed` | 422 | Request body failed validation. Uses `{"error": {"code": "validation_failed", "details": {<field>: [<message>]}}}` instead of `message`. |
| `not_found` | 404 | The addressed resource does not exist (or isn't visible to this tenant). |
| `unauthorized` | 401 | Missing or invalid credentials (tenant `api_key` or database `auth_token`). |
| `database_limit_reached` | 403 | Tenant has reached its database limit. |
| `last_api_key` | 422 | Cannot disable or delete the tenant's last usable API key. |
| `rate_limited` | 429 | Database request rate limit exceeded. |
| `signup_rate_limited` | 429 | Too many tenant signups from this IP; retry later. |
| `missing_sql` | 400 | Query request body is missing the `sql` field. |
| `query_error` | 400 | The SQL statement failed; `message` is the underlying SQLite error text (intentionally surfaced). |
| `query_timeout` | 408 | The query exceeded its timeout. |
| `transactions_not_supported` | 400 | Interactive `BEGIN`/`COMMIT`/`ROLLBACK`/`SAVEPOINT` are not supported; statements run in autocommit. |
| `database_busy_in_transaction` | 409 | The database is locked by another connection's open transaction; retry shortly. |
| `invalid_cursor` | 400 | Pagination `after` does not reference a row. |
| `invalid_limit` | 400 | Pagination `limit` is not a positive integer. |
| `no_snapshot` | 409 | Branch source has no snapshot to branch from; back it up (or let it idle) first. |
| `point_in_time_requires_litestream` | 409 | Point-in-time branching requires litestream (continuous replication) on the source. |
| `replication_disabled` | 409 | The operation requires litestream replication, which is not enabled for this database. |
| `invalid_timestamp` | 400 | `timestamp` is not an RFC3339 datetime. |
| `timestamp_out_of_window` | 422 | `timestamp` is outside the recoverable window (last 30 days, not in the future). |
| `has_branches` | 409 | The database has branches; delete them before deleting it. |
| `branch_cycle` | 409 | The tenant's databases form a branch cycle and cannot be removed. |
| `backup_not_found` | 404 | No backup (or snapshot artifact) found for this database. |

## Server errors (5xx)

The request was valid but a downstream operation failed. Includes `request_id`;
full detail is in the logs. Generally retryable.

| Code | HTTP | Meaning |
| --- | --- | --- |
| `object_storage_put` | 502 | Uploading an object to the store failed. |
| `object_storage_fetch` | 502 | Fetching an object from the store failed. |
| `object_storage_copy` | 502 | A server-side object copy failed. |
| `object_storage_delete` | 502 | Deleting an object failed. |
| `object_storage_error` | 502 | An object-store operation failed (operation not attributed). |
| `replication_error` | 502 | A litestream replication/restore operation failed. |
| `node_unavailable` | 503 | The node serving this database is temporarily unreachable (inter-node RPC failure, no healthy placement, or the recorded owner node has left the cluster — resolves once the placement row is reclaimed on the owner's boot or reassigned by evacuation). |
| `database_not_running` | 503 | The database is not currently placed on any node. |
| `database_unavailable` | 503 | The database is not active (not started, or its file is missing). |
| `internal_error` | 500 | An unclassified internal failure. The catch-all — its raw cause is only in the logs. |

## Adding a new error

Map the new `{:error, reason}` in `SmolsqlsWeb.Api.ErrorCode.classify/1` to a
`{status, code, message}`, add a row here, and cover it in
`test/smolsqls_web/controllers/api/error_code_test.exs`. Unmapped reasons fall
through to `internal_error` (500) — correct-but-opaque, never a leak.
