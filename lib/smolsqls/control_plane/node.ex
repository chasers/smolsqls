defmodule Smolsqls.ControlPlane.Node do
  @moduledoc """
  A data-plane node's cluster identity and geographic region. Each node
  upserts its own row on boot (`Smolsqls.NodeRegistry`) and heartbeats
  `last_seen_at`; region-aware placement reads these rows to constrain a
  database's owner to nodes in its region.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:node_name, :string, autogenerate: false}
  schema "nodes" do
    field :region, :string
    field :cloud, :string
    field :status, :string, default: "up"
    field :last_seen_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:node_name, :region, :cloud, :status, :last_seen_at])
    |> validate_required([:node_name, :region])
  end
end
