defmodule SmolsqlsWeb.Api.ErrorCode do
  @moduledoc """
  Single source of truth mapping an internal `{:error, reason}` term to the
  client-facing triple `{status, code, message}`.

  `code` is a stable textual class (e.g. `"object_storage_put"`,
  `"node_unavailable"`) — safe to expose and to branch on. `message` is a
  generic, non-leaking sentence. The raw `reason` is never returned to clients;
  callers log it server-side (with the request id) for any 5xx class.

  Unrecognized reasons collapse to `internal_error` (500), so a new internal
  failure mode degrades to a generic error rather than leaking its term.
  """

  @type status :: atom()
  @type classification :: {status(), code :: String.t(), message :: String.t()}

  @spec classify(term()) :: classification()
  def classify(reason)

  def classify(:not_found), do: {:not_found, "not_found", "resource not found"}

  def classify(:unauthorized),
    do: {:unauthorized, "unauthorized", "missing or invalid credentials"}

  def classify(:database_not_running),
    do:
      {:service_unavailable, "database_not_running",
       "database is not currently placed on any node"}

  def classify(:database_limit_reached),
    do: {:forbidden, "database_limit_reached", "tenant has reached its database limit"}

  def classify(:last_api_key),
    do:
      {:unprocessable_entity, "last_api_key",
       "cannot disable or delete the tenant's last usable API key"}

  def classify(:rate_limited),
    do: {:too_many_requests, "rate_limited", "database rate limit exceeded"}

  def classify(:signup_rate_limited),
    do:
      {:too_many_requests, "signup_rate_limited",
       "too many accounts created from this IP; try again later"}

  def classify(:point_in_time_requires_litestream),
    do:
      {:conflict, "point_in_time_requires_litestream",
       "point-in-time branching requires litestream (continuous replication) on the source"}

  def classify(:invalid_timestamp),
    do: {:bad_request, "invalid_timestamp", "\"timestamp\" must be an RFC3339 datetime"}

  def classify(:timestamp_out_of_window),
    do:
      {:unprocessable_entity, "timestamp_out_of_window",
       "\"timestamp\" is outside the recoverable window (last 30 days, not in the future)"}

  def classify(:no_snapshot),
    do:
      {:conflict, "no_snapshot",
       "source database has no snapshot to branch from; create a backup first"}

  def classify(:has_branches),
    do:
      {:conflict, "has_branches",
       "database has branches; delete them before deleting this database"}

  def classify(:database_busy_in_transaction),
    do:
      {:conflict, "database_busy_in_transaction",
       "database is locked by another connection's open transaction; retry shortly"}

  def classify(:query_timeout), do: {:request_timeout, "query_timeout", "query timed out"}

  def classify(:transactions_not_supported),
    do:
      {:bad_request, "transactions_not_supported",
       "interactive transactions (BEGIN/COMMIT/ROLLBACK/SAVEPOINT) are not supported; " <>
         "statements run in autocommit mode"}

  def classify(:invalid_cursor),
    do: {:bad_request, "invalid_cursor", "\"after\" does not reference a row"}

  def classify(:invalid_limit),
    do: {:bad_request, "invalid_limit", "\"limit\" must be a positive integer"}

  def classify(:missing_sql),
    do: {:bad_request, "missing_sql", "request body requires a \"sql\" field"}

  def classify({:object_store, op, _reason}) when is_atom(op),
    do: {:bad_gateway, "object_storage_#{op}", "object storage operation failed"}

  def classify({:s3_status, _status, _body}),
    do: {:bad_gateway, "object_storage_error", "object storage operation failed"}

  def classify({:litestream, _status}),
    do: {:bad_gateway, "replication_error", "replication operation failed"}

  def classify(:litestream_disabled),
    do:
      {:conflict, "replication_disabled",
       "litestream replication is not enabled for this database"}

  def classify({:badrpc, _}), do: node_unavailable()
  def classify({:badtcp, _}), do: node_unavailable()
  def classify(:no_survivors), do: node_unavailable()
  def classify(:unavailable), do: node_unavailable()
  def classify(:database_owner_unavailable), do: node_unavailable()

  def classify(:database_not_active),
    do: {:service_unavailable, "database_unavailable", "database is not active"}

  def classify(:database_file_missing),
    do: {:service_unavailable, "database_unavailable", "database is not active"}

  def classify(:backup_not_found), do: backup_not_found()
  def classify(:no_backups), do: backup_not_found()
  def classify(:no_idle_snapshot), do: backup_not_found()

  def classify(:branch_cycle),
    do: {:conflict, "branch_cycle", "databases form a branch cycle and cannot be removed"}

  def classify(reason) when is_binary(reason), do: {:bad_request, "query_error", reason}

  def classify(_reason),
    do: {:internal_server_error, "internal_error", "an internal error occurred"}

  @doc """
  Whether a classification should be logged with its raw reason and carry a
  request id to the client — true for the opaque 5xx classes.
  """
  @spec loggable?(status()) :: boolean()
  def loggable?(status), do: Plug.Conn.Status.code(status) >= 500

  defp node_unavailable,
    do:
      {:service_unavailable, "node_unavailable",
       "the node serving this database is temporarily unavailable"}

  defp backup_not_found, do: {:not_found, "backup_not_found", "no backup found for this database"}
end
