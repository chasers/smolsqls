defmodule SqlitesWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics(), name: :sqlites_prometheus}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Metrics aggregated for the Prometheus endpoint (`GET /metrics`).
  Alert conditions built on these are listed in `docs/alerts.md`.
  """
  def prometheus_metrics do
    query_buckets = [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000, 30_000]
    transfer_buckets = [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 15_000, 60_000]

    [
      last_value("sqlites.hot_servers.count",
        description: "Database servers currently hot on this node"
      ),
      counter("sqlites.query.count", tags: [:result, :remote]),
      distribution("sqlites.query.duration_ms",
        tags: [:result],
        reporter_options: [buckets: query_buckets]
      ),
      counter("sqlites.activation.count", tags: [:path]),
      distribution("sqlites.activation.duration_ms",
        tags: [:path],
        reporter_options: [buckets: transfer_buckets]
      ),
      counter("sqlites.idle_snapshot.ship.count", tags: [:result]),
      distribution("sqlites.idle_snapshot.ship.duration_ms",
        tags: [:result],
        reporter_options: [buckets: transfer_buckets]
      ),
      sum("sqlites.cache_evictor.sweep.evicted"),
      sum("sqlites.cache_evictor.sweep.freed_bytes"),
      counter("sqlites.node_operation.count", tags: [:kind, :result]),
      counter("sqlites.rate_limiter.rejected.count"),
      counter("sqlites.fence.stopped.count"),
      sum("sqlites.reconciler.claimed.count"),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: query_buckets]
      )
    ]
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("sqlites.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("sqlites.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("sqlites.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("sqlites.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("sqlites.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {Sqlites.Telemetry, :emit_hot_servers, []}
    ]
  end
end
