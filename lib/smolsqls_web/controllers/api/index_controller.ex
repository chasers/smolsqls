defmodule SmolsqlsWeb.Api.IndexController do
  @moduledoc """
  Machine-readable API index so an agent can bootstrap the full
  lifecycle — signup, database CRUD, queries, backups — from the base
  URL alone.
  """

  use SmolsqlsWeb, :controller

  def index(conn, _params) do
    base = SmolsqlsWeb.Endpoint.url()

    json(conn, %{
      service: "smolsqls",
      description:
        "Multitenant SQLite database service. Sign up for a tenant, create databases, " <>
          "connect with any libSQL client or plain HTTP. All management endpoints " <>
          "authenticate with 'Authorization: Bearer <tenant api_key>'; query endpoints " <>
          "authenticate with the per-database auth_token.",
      response_format:
        "Every successful (2xx) body is a JSON object {\"data\": <object>}; the fields " <>
          "documented per endpoint live inside \"data\". List endpoints add a top-level " <>
          "\"next\" cursor alongside \"data\" (null on the last page). Secrets and " <>
          "connection strings (tenant \"api_key\", database \"auth_token\", " <>
          "\"connections\") appear only in the create response's \"data\" and are never " <>
          "echoed by later GETs.",
      error_format:
        "Errors (4xx/5xx) are {\"error\": {\"code\": <string>, \"message\": <string>}}. " <>
          "\"code\" is a stable textual class (e.g. \"not_found\", \"object_storage_put\"). " <>
          "5xx errors also include a \"request_id\" for log correlation; raw internal " <>
          "detail is logged server-side, never returned. Validation errors use " <>
          "{\"error\": {\"code\": \"validation_failed\", \"details\": {<field>: [<message>]}}}.",
      endpoints: endpoints(base)
    })
  end

  defp endpoint(method, path, auth, extra \\ []) do
    Enum.into(extra, %{method: method, path: path, auth: auth})
  end

  defp endpoints(base) do
    [
      endpoint("POST", "#{base}/v1/tenants", "none",
        body: %{name: "My Org", slug: "my-org"},
        returns: "tenant with api_key — store it, it is shown only once"
      ),
      endpoint("GET", "#{base}/v1/tenant", "tenant api_key"),
      endpoint("PATCH", "#{base}/v1/tenant", "tenant api_key", body: %{name: "..."}),
      endpoint("DELETE", "#{base}/v1/tenant", "tenant api_key"),
      endpoint("GET", "#{base}/v1/tenant/keys", "tenant api_key",
        returns: "key metadata only — secrets come from create or reveal"
      ),
      endpoint("POST", "#{base}/v1/tenant/keys", "tenant api_key",
        body: %{name: "ci", expires_at: "2027-01-01T00:00:00Z"},
        returns: "a new permanent API key; name and expires_at are optional"
      ),
      endpoint("POST", "#{base}/v1/tenant/keys/:id/reveal", "tenant api_key",
        returns: "the key's secret, decrypted on explicit request"
      ),
      endpoint("PATCH", "#{base}/v1/tenant/keys/:id", "tenant api_key",
        body: %{enabled: false},
        returns: "enable/disable a key (the last usable key cannot be disabled)"
      ),
      endpoint("DELETE", "#{base}/v1/tenant/keys/:id", "tenant api_key"),
      endpoint("GET", "#{base}/v1/databases?after=<id>&limit=<n>", "tenant api_key",
        returns: "page of databases plus a next cursor (null on the last page)"
      ),
      endpoint("POST", "#{base}/v1/databases", "tenant api_key",
        body: %{name: "my-task-db", region: "gcp-us-central1"},
        returns:
          "database with auth_token and ready-to-use connection strings (under " <>
            "data.connections) — returned only here, never by GET /databases/:id. " <>
            "region is optional (defaults to the cluster default) and omitted where " <>
            "regions are not configured"
      ),
      endpoint("GET", "#{base}/v1/databases/:id", "tenant api_key"),
      endpoint("PATCH", "#{base}/v1/databases/:id", "tenant api_key",
        body: %{litestream_enabled: true, region: "gcp-europe-west1"},
        returns:
          "toggle continuous (litestream) replication and/or move the database to a " <>
            "new region (relocates its file; queries are briefly retryable during the move)"
      ),
      endpoint("DELETE", "#{base}/v1/databases/:id", "tenant api_key"),
      endpoint("GET", "#{base}/v1/databases/:id/tokens", "tenant api_key",
        returns: "token metadata only — secrets come from create or reveal"
      ),
      endpoint("POST", "#{base}/v1/databases/:id/tokens", "tenant api_key",
        body: %{name: "worker", expires_at: "2027-01-01T00:00:00Z"},
        returns: "a new permanent database token; name and expires_at are optional"
      ),
      endpoint("POST", "#{base}/v1/databases/:id/tokens/:token_id/reveal", "tenant api_key",
        returns: "the token's secret, decrypted on explicit request"
      ),
      endpoint("PATCH", "#{base}/v1/databases/:id/tokens/:token_id", "tenant api_key",
        body: %{enabled: false},
        returns: "enable/disable a token"
      ),
      endpoint("DELETE", "#{base}/v1/databases/:id/tokens/:token_id", "tenant api_key"),
      endpoint("POST", "#{base}/v1/databases/:id/query", "database auth_token",
        body: %{sql: "SELECT * FROM t WHERE id = ?", args: [1]},
        returns: "columns, rows, num_changes"
      ),
      endpoint(
        "GET",
        "#{base}/v1/databases/:id/changes?max_events=<n>&timeout_ms=<ms>",
        "database auth_token",
        returns:
          "Server-Sent Events stream of the database's row changes: one " <>
            "'event: change' frame per insert/update/delete with data " <>
            "{action, table, rowid, record}; record is null for deletes. " <>
            "Both query params are optional (default 5-minute stream, 10-minute max)"
      ),
      endpoint("GET", "#{base}/v1/databases/:id/backups?after=<id>&limit=<n>", "tenant api_key",
        returns: "page of backups plus a next cursor (null on the last page)"
      ),
      endpoint("POST", "#{base}/v1/databases/:id/backups", "tenant api_key"),
      endpoint("GET", "#{base}/v1/databases/:id/backups/:backup_id/download", "tenant api_key",
        returns: "the backup's SQLite file (application/vnd.sqlite3) as a download"
      ),
      endpoint("POST", "#{base}/v1/databases/:id/restore", "tenant api_key",
        body: %{backup_id: "..."}
      )
    ]
  end
end
