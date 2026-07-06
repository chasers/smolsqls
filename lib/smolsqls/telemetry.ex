defmodule Smolsqls.Telemetry do
  @moduledoc """
  Data-plane telemetry: event names, emission helpers, and the
  periodic measurements polled by `SmolsqlsWeb.Telemetry`. Everything
  here lands on the Prometheus endpoint (`GET /metrics`); the alert
  conditions worth paging on are documented in `docs/alerts.md`.

  Events:

    * `[:smolsqls, :query]` — `%{count, duration_ms}`, tags `result`
      (`ok` | `error` | `badrpc`), `remote` (`true` | `false`)
    * `[:smolsqls, :activation]` — `%{count, duration_ms}`, tag `path`
      (`cache_hit` | `litestream` | `idle_snapshot` | `backup` |
      `missing`)
    * `[:smolsqls, :idle_snapshot, :ship]` — `%{count, duration_ms}`,
      tag `result` (`ok` | `error`)
    * `[:smolsqls, :cache_evictor, :sweep]` — `%{evicted, freed_bytes}`
    * `[:smolsqls, :backup_sweep]` — `%{due, backed_up}` (daily-backup
      guarantee; one sweep per cluster per tick)
    * `[:smolsqls, :backup_sla]` — `%{in_breach, oldest_age_seconds}`
      (polled; active databases past the daily-backup window and the
      worst backup gap across the fleet)
    * `[:smolsqls, :node_operation]` — `%{count, reassigned}`, tags
      `kind` (`drain` | `evacuate`), `result` (`ok` | `error` |
      `cancelled`)
    * `[:smolsqls, :rate_limiter, :rejected]` — `%{count}`
    * `[:smolsqls, :fence, :stopped]` — `%{count}`
    * `[:smolsqls, :hot_servers]` — `%{count}` (polled)
  """

  @spec query(integer(), atom() | String.t(), boolean()) :: :ok
  def query(duration_ms, result, remote) do
    :telemetry.execute(
      [:smolsqls, :query],
      %{count: 1, duration_ms: duration_ms},
      %{result: to_string(result), remote: to_string(remote)}
    )
  end

  @spec activation(String.t(), integer()) :: :ok
  def activation(path, duration_ms \\ 0) do
    :telemetry.execute(
      [:smolsqls, :activation],
      %{count: 1, duration_ms: duration_ms},
      %{path: path}
    )
  end

  @spec ship(integer(), atom()) :: :ok
  def ship(duration_ms, result) do
    :telemetry.execute(
      [:smolsqls, :idle_snapshot, :ship],
      %{count: 1, duration_ms: duration_ms},
      %{result: to_string(result)}
    )
  end

  @spec eviction_sweep(non_neg_integer(), non_neg_integer()) :: :ok
  def eviction_sweep(evicted, freed_bytes) do
    :telemetry.execute(
      [:smolsqls, :cache_evictor, :sweep],
      %{evicted: evicted, freed_bytes: freed_bytes},
      %{}
    )
  end

  @spec backup_sweep(non_neg_integer(), non_neg_integer()) :: :ok
  def backup_sweep(due, backed_up) do
    :telemetry.execute([:smolsqls, :backup_sweep], %{due: due, backed_up: backed_up}, %{})
  end

  @spec node_operation(String.t(), atom(), non_neg_integer()) :: :ok
  def node_operation(kind, result, reassigned \\ 0) do
    :telemetry.execute(
      [:smolsqls, :node_operation],
      %{count: 1, reassigned: reassigned},
      %{kind: kind, result: to_string(result)}
    )
  end

  @spec rate_limited() :: :ok
  def rate_limited do
    :telemetry.execute([:smolsqls, :rate_limiter, :rejected], %{count: 1}, %{})
  end

  @spec fenced() :: :ok
  def fenced do
    :telemetry.execute([:smolsqls, :fence, :stopped], %{count: 1}, %{})
  end

  @doc """
  Poller measurement: how many database servers are hot on this node.
  """
  @spec emit_hot_servers() :: :ok
  def emit_hot_servers do
    count = :syn.registry_count(Smolsqls.DataPlane.Registry.scope(), Node.self())
    :telemetry.execute([:smolsqls, :hot_servers], %{count: count}, %{})
  end

  @doc """
  Poller measurement for the daily-backup SLA: emits how many active
  databases are past the backup window and the worst backup gap. Runs
  on every node against the metadb independently of the sweeper, so a
  dead or stuck sweeper does not blind the alert; failures are swallowed
  so a transient metadb hiccup never crashes the poller.
  """
  @spec emit_backup_sla() :: :ok
  def emit_backup_sla do
    %{in_breach: in_breach, oldest_age_seconds: oldest_age_seconds} =
      Smolsqls.Backups.sla_stats(sla_breach_ms())

    :telemetry.execute(
      [:smolsqls, :backup_sla],
      %{in_breach: in_breach, oldest_age_seconds: oldest_age_seconds},
      %{}
    )
  rescue
    _ -> :ok
  end

  defp sla_breach_ms do
    Application.get_env(:smolsqls, Smolsqls.Backups.Sweeper, [])[:sla_breach_ms] ||
      :timer.hours(28)
  end
end
