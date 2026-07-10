defmodule Smolsqls.NodeRegistry do
  @moduledoc """
  Publishes this node's cluster identity and region to the `nodes` metadb
  table so region-aware placement can find it. Upserts on boot and refreshes
  `last_seen_at` on an interval. Starts only when a region is configured for
  this node (`config :smolsqls, :region`); otherwise it `:ignore`s, leaving
  the region system dormant in dev/test and single-cluster deployments.
  """

  use GenServer

  require Logger

  alias Smolsqls.ControlPlane

  @heartbeat_interval :timer.seconds(30)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case Smolsqls.Regions.self_region() do
      nil ->
        :ignore

      region ->
        register(region)
        schedule_heartbeat()
        {:ok, %{region: region}}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    ControlPlane.heartbeat_node(node_name())
    schedule_heartbeat()
    {:noreply, state}
  end

  defp register(region) do
    case ControlPlane.upsert_node(node_name(), region) do
      {:ok, _node} ->
        :ok

      {:error, reason} ->
        Logger.warning("node registration for #{node_name()} failed: #{inspect(reason)}")
        :ok
    end
  end

  defp schedule_heartbeat, do: Process.send_after(self(), :heartbeat, @heartbeat_interval)

  defp node_name, do: to_string(Node.self())
end
