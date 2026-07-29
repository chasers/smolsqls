defmodule Smolsqls.Telemetry do
  @moduledoc """
  Data-plane telemetry: event names, emission helpers, and the
  periodic measurements polled by `SmolsqlsWeb.Telemetry`. Everything
  here lands on the Prometheus endpoint (`GET /metrics`); the alert
  conditions worth paging on are documented in `docs/alerts.md`.

  Events:

    * `[:smolsqls, :query]` — `%{count, duration_ms}`, tags `result`
      (`ok` | `error` | `badrpc`), `remote` (`true` | `false`),
      `cold` (`true` | `false`) — `true` when the query had to activate
      the server (cold start, including any restore from the object
      store); the `[:smolsqls, :activation]` event carries the
      restore-path breakdown for those
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
    * `[:smolsqls, :syn, :conflict_resolved]` — `%{count}` (registry
      conflict resolved at partition heal or reassign race)
    * `[:smolsqls, :read_model, :entries]` — `%{entries, memory_bytes}`,
      tag `table` (polled; cache size per table)
    * `[:smolsqls, :read_model, :counters]` — `%{hits, negative_hits,
      misses, refreshes, collapsed, load_timeouts, load_failures,
      discarded, expired, evicted}` (polled, cumulative). `misses` is
      metadb read load; `discarded` counts loads thrown away because the
      key was mutated mid-flight
    * `[:smolsqls, :read_model, :health]` — `%{inflight, stale}`
      (polled). `stale` is 1 while the metadb is unreachable, which is
      also when entry expiry is paused and the node is serving whatever
      it last loaded
    * `[:smolsqls, :read_model, :sweep]` — `%{expired, evicted}`
    * `[:smolsqls, :read_model, :load_discarded]` — `%{count}`, tag
      `table`
    * `[:smolsqls, :read_model, :load_failed]` — `%{count}`, tag `table`
    * `[:smolsqls, :read_model, :flushed]` — `%{count}`, tag `reason`
  """

  @spec query(integer(), atom() | String.t(), boolean(), boolean()) :: :ok
  def query(duration_ms, result, remote, cold) do
    :telemetry.execute(
      [:smolsqls, :query],
      %{count: 1, duration_ms: duration_ms},
      %{result: to_string(result), remote: to_string(remote), cold: to_string(cold)}
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

  @spec syn_conflict_resolved() :: :ok
  def syn_conflict_resolved do
    :telemetry.execute([:smolsqls, :syn, :conflict_resolved], %{count: 1}, %{})
  end

  @spec read_model_sweep(non_neg_integer(), non_neg_integer()) :: :ok
  def read_model_sweep(expired, evicted) do
    :telemetry.execute(
      [:smolsqls, :read_model, :sweep],
      %{expired: expired, evicted: evicted},
      %{}
    )
  end

  @spec read_model_load_discarded(atom()) :: :ok
  def read_model_load_discarded(table) do
    :telemetry.execute(
      [:smolsqls, :read_model, :load_discarded],
      %{count: 1},
      %{table: to_string(table)}
    )
  end

  @spec read_model_load_failed(atom()) :: :ok
  def read_model_load_failed(table) do
    :telemetry.execute(
      [:smolsqls, :read_model, :load_failed],
      %{count: 1},
      %{table: to_string(table)}
    )
  end

  @spec read_model_flushed(atom()) :: :ok
  def read_model_flushed(reason) do
    :telemetry.execute(
      [:smolsqls, :read_model, :flushed],
      %{count: 1},
      %{reason: to_string(reason)}
    )
  end

  @doc """
  Poller measurement for the read-model cache: per-table size, the
  cumulative hit/miss/refresh counters, and whether this node is
  currently serving a cache it cannot refresh.
  """
  @spec emit_read_model() :: :ok
  def emit_read_model do
    case Smolsqls.ReadModel.stats() do
      %{tables: tables, counters: counters} = stats ->
        for {table, %{entries: entries, memory_bytes: memory_bytes}} <- tables do
          :telemetry.execute(
            [:smolsqls, :read_model, :entries],
            %{entries: entries, memory_bytes: memory_bytes},
            %{table: to_string(table)}
          )
        end

        :telemetry.execute([:smolsqls, :read_model, :counters], counters, %{})

        :telemetry.execute(
          [:smolsqls, :read_model, :health],
          %{inflight: stats.inflight, stale: if(stats.metadb_ok?, do: 0, else: 1)},
          %{}
        )

      _not_running ->
        :ok
    end
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
