defmodule Smolsqls.ReadModel.Projection do
  @moduledoc """
  The columns the request path actually reads — the single list that
  decides what the cache holds.

  Three paths populate an entry and all must produce the same shape, or a
  row would carry a field on one path and `nil` on another:
  `Smolsqls.ReadModel.Source` selects these columns from Postgres on a
  miss, `Smolsqls.ReadModel.Row` builds them from the WAL feed's text
  values, and local write-through projects the row it just wrote.
  Everything else on the struct stays `nil` on purpose.

  `tenants` carries the fields management responses render, not just the
  `limits` the query path needs, so management auth resolves a renderable
  tenant without reading Postgres. It is the smallest of the four tables,
  so paying for a few more columns there is cheaper than a second lookup
  on every dashboard request.

  Adding a column the data plane needs means adding it here, teaching
  `Row` how to decode it, and widening the publication (a migration —
  publications are DDL, so that list is deliberately not generated from
  this one).
  """

  @databases [
    :id,
    :tenant_id,
    :status,
    :node,
    :region,
    :cloud,
    :file_path,
    :litestream_enabled,
    :snapshot_generation,
    :limits
  ]

  @tenants [:id, :name, :slug, :limits, :inserted_at]
  @database_tokens [:id, :database_id, :token_hash, :enabled, :expires_at]
  @tenant_api_keys [:id, :tenant_id, :token_hash, :enabled, :expires_at]

  @spec fields(Smolsqls.ReadModel.table()) :: [atom()]
  def fields(:databases), do: @databases
  def fields(:tenants), do: @tenants
  def fields(:database_tokens), do: @database_tokens
  def fields(:tenant_api_keys), do: @tenant_api_keys

  @doc """
  Narrows a row to the projected fields, so a row cached by local
  write-through is shaped like one loaded from Postgres or built from the
  feed rather than carrying every column it happened to be written with.
  """
  @spec project(Smolsqls.ReadModel.table(), struct()) :: struct()
  def project(table, %schema{} = row) do
    struct(schema, Map.take(row, fields(table)))
  end
end
