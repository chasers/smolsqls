defmodule Smolsqls.DataPlane.Placement do
  @moduledoc """
  Chooses which cluster node should own a new database — the live node
  running the fewest database servers. When the database requests a region,
  candidates are first constrained to the live nodes recorded in that region
  (`nodes` table); a region with no live node is rejected rather than
  silently placed elsewhere. A `nil` region (dev/test, single-cluster) keeps
  placement purely load-based across the whole cluster.
  """

  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane.Registry

  @spec pick_node(String.t() | nil) :: node() | {:error, :no_capacity_in_region}
  def pick_node(region \\ nil)

  def pick_node(nil) do
    [Node.self() | Node.list()]
    |> Enum.min_by(&database_count/1)
  end

  def pick_node(region) when is_binary(region) do
    in_region = MapSet.new(ControlPlane.nodes_in_region(region))

    [Node.self() | Node.list()]
    |> Enum.filter(&MapSet.member?(in_region, to_string(&1)))
    |> case do
      [] -> {:error, :no_capacity_in_region}
      candidates -> Enum.min_by(candidates, &database_count/1)
    end
  end

  defp database_count(node) do
    :syn.registry_count(Registry.scope(), node)
  end
end
