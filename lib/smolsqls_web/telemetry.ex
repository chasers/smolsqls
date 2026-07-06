defmodule SmolsqlsWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      ] ++
        backup_sla_pollers() ++
        [{Peep, name: :smolsqls_peep, metrics: prometheus_metrics(), storage: :striped}]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Metrics aggregated for the Prometheus endpoint (`GET /metrics`).
  Alert conditions built on these are listed in `docs/alerts.md`.

  Aggregation is Peep with striped storage — one ETS table per
  scheduler — because telemetry handlers run inline in the emitting
  process and the query path emits on every call; a shared-table
  reporter costs measurable throughput under concurrent load (see
  bench/qps/RESULTS.md).
  """
  def prometheus_metrics do
    query_buckets = [peep_bucket_calculator: SmolsqlsWeb.Telemetry.QueryBuckets]
    transfer_buckets = [peep_bucket_calculator: SmolsqlsWeb.Telemetry.TransferBuckets]

    [
      last_value("smolsqls.hot_servers.count",
        description: "Database servers currently hot on this node"
      ),
      counter("smolsqls.query.count", tags: [:result, :remote]),
      distribution("smolsqls.query.duration_ms",
        tags: [:result],
        reporter_options: query_buckets
      ),
      counter("smolsqls.activation.count", tags: [:path]),
      distribution("smolsqls.activation.duration_ms",
        tags: [:path],
        reporter_options: transfer_buckets
      ),
      counter("smolsqls.idle_snapshot.ship.count", tags: [:result]),
      distribution("smolsqls.idle_snapshot.ship.duration_ms",
        tags: [:result],
        reporter_options: transfer_buckets
      ),
      sum("smolsqls.cache_evictor.sweep.evicted"),
      sum("smolsqls.cache_evictor.sweep.freed_bytes"),
      sum("smolsqls.backup_sweep.backed_up"),
      last_value("smolsqls.backup_sla.in_breach",
        description: "Active databases past the daily-backup window with no recent backup"
      ),
      last_value("smolsqls.backup_sla.oldest_age_seconds",
        description: "Age in seconds of the worst backup gap across active databases"
      ),
      counter("smolsqls.node_operation.count", tags: [:kind, :result]),
      counter("smolsqls.rate_limiter.rejected.count"),
      counter("smolsqls.fence.stopped.count"),
      sum("smolsqls.reconciler.claimed.count"),
      distribution("phoenix.router_dispatch.stop.duration_ms",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: fn %{duration: duration} ->
          System.convert_time_unit(duration, :native, :millisecond)
        end,
        tags: [:route],
        reporter_options: query_buckets
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
      summary("smolsqls.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("smolsqls.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("smolsqls.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("smolsqls.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("smolsqls.repo.query.idle_time",
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
      {Smolsqls.Telemetry, :emit_hot_servers, []}
    ]
  end

  defp backup_sla_pollers do
    if Application.get_env(:smolsqls, __MODULE__, [])[:backup_sla_poller] == false do
      []
    else
      [
        {:telemetry_poller,
         measurements: [{Smolsqls.Telemetry, :emit_backup_sla, []}],
         period: 60_000,
         name: :smolsqls_backup_sla_poller}
      ]
    end
  end
end
