defmodule SqlitesWeb.Api.IndexController do
  @moduledoc """
  Machine-readable API index so an agent can bootstrap the full
  lifecycle — signup, database CRUD, queries, backups — from the base
  URL alone.
  """

  use SqlitesWeb, :controller

  def index(conn, _params) do
    base = SqlitesWeb.Endpoint.url()

    json(conn, %{
      service: "sqlites",
      description:
        "Multitenant SQLite database service. Sign up for a tenant, create databases, " <>
          "connect with any libSQL client or plain HTTP. All management endpoints " <>
          "authenticate with 'Authorization: Bearer <tenant api_key>'; query endpoints " <>
          "authenticate with the per-database auth_token.",
      endpoints: [
        %{
          method: "POST",
          path: "#{base}/v1/tenants",
          auth: "none",
          body: %{name: "My Org", slug: "my-org"},
          returns: "tenant with api_key — store it, it is shown only once"
        },
        %{method: "GET", path: "#{base}/v1/tenant", auth: "tenant api_key"},
        %{
          method: "PATCH",
          path: "#{base}/v1/tenant",
          auth: "tenant api_key",
          body: %{name: "..."}
        },
        %{method: "DELETE", path: "#{base}/v1/tenant", auth: "tenant api_key"},
        %{
          method: "GET",
          path: "#{base}/v1/tenant/keys",
          auth: "tenant api_key",
          returns: "key metadata only — secrets come from create or reveal"
        },
        %{
          method: "POST",
          path: "#{base}/v1/tenant/keys",
          auth: "tenant api_key",
          body: %{name: "ci", expires_at: "2027-01-01T00:00:00Z"},
          returns: "a new permanent API key; name and expires_at are optional"
        },
        %{
          method: "POST",
          path: "#{base}/v1/tenant/keys/:id/reveal",
          auth: "tenant api_key",
          returns: "the key's secret, decrypted on explicit request"
        },
        %{
          method: "PATCH",
          path: "#{base}/v1/tenant/keys/:id",
          auth: "tenant api_key",
          body: %{enabled: false},
          returns: "enable/disable a key (the last usable key cannot be disabled)"
        },
        %{method: "DELETE", path: "#{base}/v1/tenant/keys/:id", auth: "tenant api_key"},
        %{
          method: "GET",
          path: "#{base}/v1/databases?after=<id>&limit=<n>",
          auth: "tenant api_key",
          returns: "page of databases plus a next cursor (null on the last page)"
        },
        %{
          method: "POST",
          path: "#{base}/v1/databases",
          auth: "tenant api_key",
          body: %{name: "my-task-db"},
          returns: "database with auth_token and ready-to-use connection strings"
        },
        %{method: "GET", path: "#{base}/v1/databases/:id", auth: "tenant api_key"},
        %{
          method: "PATCH",
          path: "#{base}/v1/databases/:id",
          auth: "tenant api_key",
          body: %{litestream_enabled: true},
          returns: "toggle continuous (litestream) replication for this database"
        },
        %{method: "DELETE", path: "#{base}/v1/databases/:id", auth: "tenant api_key"},
        %{
          method: "GET",
          path: "#{base}/v1/databases/:id/tokens",
          auth: "tenant api_key",
          returns: "token metadata only — secrets come from create or reveal"
        },
        %{
          method: "POST",
          path: "#{base}/v1/databases/:id/tokens",
          auth: "tenant api_key",
          body: %{name: "worker", expires_at: "2027-01-01T00:00:00Z"},
          returns: "a new permanent database token; name and expires_at are optional"
        },
        %{
          method: "POST",
          path: "#{base}/v1/databases/:id/tokens/:token_id/reveal",
          auth: "tenant api_key",
          returns: "the token's secret, decrypted on explicit request"
        },
        %{
          method: "PATCH",
          path: "#{base}/v1/databases/:id/tokens/:token_id",
          auth: "tenant api_key",
          body: %{enabled: false},
          returns: "enable/disable a token"
        },
        %{
          method: "DELETE",
          path: "#{base}/v1/databases/:id/tokens/:token_id",
          auth: "tenant api_key"
        },
        %{
          method: "POST",
          path: "#{base}/v1/databases/:id/query",
          auth: "database auth_token",
          body: %{sql: "SELECT * FROM t WHERE id = ?", args: [1]},
          returns: "columns, rows, num_changes"
        },
        %{
          method: "GET",
          path: "#{base}/v1/databases/:id/backups?after=<id>&limit=<n>",
          auth: "tenant api_key",
          returns: "page of backups plus a next cursor (null on the last page)"
        },
        %{method: "POST", path: "#{base}/v1/databases/:id/backups", auth: "tenant api_key"},
        %{
          method: "POST",
          path: "#{base}/v1/databases/:id/restore",
          auth: "tenant api_key",
          body: %{backup_id: "..."}
        }
      ]
    })
  end
end
