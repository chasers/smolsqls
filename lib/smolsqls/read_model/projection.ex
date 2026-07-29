defmodule Smolsqls.ReadModel.Projection do
  @moduledoc """
  The columns the query path actually reads — the single list that
  decides what the cache holds.

  Two paths populate an entry and both must produce the same shape, or a
  row would carry a field on one path and `nil` on the other:
  `Smolsqls.ReadModel.Source` selects these columns from Postgres on a
  miss, and `Smolsqls.ReadModel.Row` builds them from the WAL feed's text
  values. Everything else on the struct stays `nil` on purpose.

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

  @tenants [:id, :limits]
  @database_tokens [:id, :database_id, :token_hash, :enabled, :expires_at]

  @spec fields(Smolsqls.ReadModel.table()) :: [atom()]
  def fields(:databases), do: @databases
  def fields(:tenants), do: @tenants
  def fields(:database_tokens), do: @database_tokens
end
