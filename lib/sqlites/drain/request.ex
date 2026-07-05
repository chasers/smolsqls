defmodule Sqlites.Drain.Request do
  @moduledoc """
  A row in `node_drains` — the metadb-mediated drain bus. The operator
  (or an admin) inserts a request for a node; any data-plane node
  claims and executes it, then reports completion on the same row. One
  request per node: re-draining a node requires deleting its row.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:node, :string, autogenerate: false}
  schema "node_drains" do
    field :requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :started_by, :string
    field :completed_at, :utc_datetime_usec
    field :reassigned, :integer
    field :error, :string
  end
end
