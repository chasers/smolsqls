defmodule Smolsqls.Regions do
  @moduledoc """
  The set of regions this cluster serves and the default assigned when a
  database is created without one. Both are configuration, not rows:

      config :smolsqls,
        region: "gcp-us-central1",          # this node's own region
        regions: ["gcp-us-central1", ...],  # regions a database may request
        default_region: "gcp-us-central1"

  A region slug is a single hyphenated DNS label combining cloud and
  provider-native region (`gcp-us-central1`, `aws-us-east-1`), used verbatim
  as the second label of a regional connection host. When `regions` is empty
  (dev/test, single-cluster), the region system is dormant: databases carry no
  region and placement stays purely load-based.
  """

  @spec all() :: [String.t()]
  def all, do: Application.get_env(:smolsqls, :regions, [])

  @spec default() :: String.t() | nil
  def default, do: Application.get_env(:smolsqls, :default_region)

  @spec self_region() :: String.t() | nil
  def self_region, do: Application.get_env(:smolsqls, :region)

  @spec enabled?() :: boolean()
  def enabled?, do: all() != []

  @doc """
  The hosting provider a region slug belongs to — the segment before the
  first hyphen (`gcp-us-central1` → `"gcp"`, `aws-us-east-1` → `"aws"`).
  Returns `nil` for a `nil` or unprefixed slug.
  """
  @spec cloud(String.t() | nil) :: String.t() | nil
  def cloud(nil), do: nil

  def cloud(region) when is_binary(region) do
    case String.split(region, "-", parts: 2) do
      [cloud, _rest] -> cloud
      _ -> nil
    end
  end
end
