defmodule Smolsqls.ReadModel do
  @moduledoc """
  Bounded read-through cache over the request-path metadb tables
  (`databases`, `database_tokens`, `tenant_api_keys`, `tenants`), holding
  only the columns the request path reads and only the rows it has
  recently asked for. So memory scales with this node's working set
  rather than with the size of the fleet, and a query for a
  recently-active database is served while Postgres is unreachable.

  Postgres remains the source of truth. Entries arrive three ways: a
  read-through load on a miss, write-through from a local control-plane
  mutation, and the WAL feed (`Smolsqls.ReadModel.Replication`) for
  changes made on other nodes. The feed only *updates rows already
  held* — it never populates — so it cannot grow the cache back into a
  full replica; deletes always apply, so a revocation propagates
  immediately to every node holding the token.

  `collapsed` counts reads that avoided a redundant metadb query — by
  joining an in-flight load, or by finding the row already cached when
  the load request reached this process.

  A hit is a single `:ets.lookup/2` and never writes: an entry stays
  alive because a hit past its refresh threshold schedules a background
  reload, not because reads stamp it. That keeps the hot path off the
  table-wide write lock, and it means a frequently-used entry is
  reloaded while still valid — the reason frequent callers keep working
  through a metadb outage. A load that fails leaves the existing entry
  alone and pauses expiry, so entries go stale rather than vanishing
  mid-incident.

  Each ETS row is `{key, {:ok, row} | :missing, loaded_at}`, which is what
  the sweeper's match specs read.

  Over the entry cap, eviction takes negative entries first and then the
  least-recently-loaded rows — refresh-ahead keeps live entries young, so
  that approximates LRU without a write on read. Priority is encoded as
  the sort order of `{rank, loaded_at, key}` (rank 0 negative, 1 present),
  and victims are picked with a bounded top-k fold rather than a full
  sort: a cap breach costs `O(n log k)` time and `O(k)` memory instead of
  a sorted copy of the table.

  Every ETS write happens in this process; the tables are `:protected`
  so that is enforced rather than conventional. Writes also invalidate
  any in-flight load for the same key, because a load that started
  before a delete would otherwise reinsert the row and hold it for a
  full TTL.

  A cached row carries every column the schema has, minus credential
  ciphertexts (`Smolsqls.ReadModel.CachedRow`), so it reads exactly like
  one loaded from Postgres and no caller needs to know where it came
  from. It is still read-only: an entry can be stale, so writes go to
  Postgres by id rather than re-writing a whole row from cache.
  """

  use GenServer

  require Logger

  alias Smolsqls.ReadModel.{CachedRow, Source}
  alias Smolsqls.Telemetry

  @databases __MODULE__.Databases
  @database_tokens __MODULE__.DatabaseTokens
  @tenant_api_keys __MODULE__.TenantApiKeys
  @tenants __MODULE__.Tenants

  @tables %{
    databases: @databases,
    database_tokens: @database_tokens,
    tenant_api_keys: @tenant_api_keys,
    tenants: @tenants
  }

  @counter_names [
    :hits,
    :negative_hits,
    :misses,
    :refreshes,
    :collapsed,
    :load_timeouts,
    :load_failures,
    :discarded,
    :expired,
    :evicted
  ]

  @counter_index @counter_names |> Enum.with_index(1) |> Map.new()

  @defaults %{
    ttl_ms: :timer.hours(24),
    negative_ttl_ms: :timer.seconds(30),
    refresh_ratio: 0.5,
    refresh_jitter_ms: :timer.minutes(30),
    max_entries: 250_000,
    sweep_interval_ms: :timer.minutes(1),
    evict_hysteresis: 0.1,
    load_timeout_ms: :timer.seconds(15)
  }

  @type table :: :databases | :database_tokens | :tenant_api_keys | :tenants
  @type entry :: {:ok, struct()} | :missing
  @type result :: {:ok, struct()} | {:error, :not_found} | {:error, :metadb_unavailable}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Whether this node is caching at all (see `config :smolsqls,
  Smolsqls.ReadModel, enabled: false`, which tests use).

  Keyed on the tables existing rather than on the process being
  registered: a named GenServer is registered before `init/1` runs, so a
  liveness check would claim the cache is usable while its tables are
  still being created.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: :ets.whereis(@databases) != :undefined

  @doc """
  Reads a row, loading it from Postgres when this node does not hold it.
  A hit past its refresh threshold schedules a background reload and
  returns immediately; concurrent misses on one key collapse into a
  single load. With caching disabled, reads go straight to Postgres.
  """
  @spec fetch(table(), String.t()) :: result()
  def fetch(table, key) do
    cond do
      not Source.valid_key?(table, key) -> {:error, :not_found}
      not enabled?() -> Source.fetch(table, key)
      true -> fetch_cached(table, key)
    end
  end

  defp fetch_cached(table, key) do
    case :ets.lookup(table!(table), key) do
      [{^key, {:ok, row}, loaded_at}] ->
        bump(:hits)
        maybe_refresh(table, key, loaded_at)
        {:ok, row}

      [{^key, :missing, _loaded_at}] ->
        bump(:negative_hits)
        {:error, :not_found}

      [] ->
        bump(:misses)
        load(table, key)
    end
  end

  @doc """
  Local write-through: caches the row unconditionally. It was just
  mutated on this node and is about to be read back, and the volume is
  the control-plane mutation rate.
  """
  @spec put(table(), struct()) :: :ok
  def put(table, row) do
    call_owner({:put, table, key_for(table, row), CachedRow.narrow(table, row)})
  end

  @doc """
  WAL feed apply: replaces the row only if this node already holds an
  entry for its key, so remote changes never populate the cache. A held
  negative entry counts as held, so a create arriving for a key cached
  as missing replaces it.
  """
  @spec replace_if_cached(table(), struct()) :: :ok
  def replace_if_cached(table, row) do
    call_owner({:replace_if_cached, table, key_for(table, row), CachedRow.narrow(table, row)})
  end

  @doc """
  Drops a key, leaving a negative entry when one was held so a client
  retrying a deleted database is not read through to Postgres. Always
  applied, from both the feed and local write-through.
  """
  @spec delete(table(), String.t()) :: :ok
  def delete(table, key), do: call_owner({:delete, table, key})

  @doc """
  Drops the entry a row would be cached under, for callers holding the
  row rather than its cache key.
  """
  @spec delete_row(table(), struct()) :: :ok
  def delete_row(table, row), do: delete(table, key_for(table, row))

  @spec truncate(table()) :: :ok
  def truncate(table), do: call_owner({:truncate, table})

  @doc """
  Drops every entry — used when the replication slot has been
  invalidated and the feed can no longer be trusted to have delivered
  its deletes.
  """
  @spec flush(atom()) :: :ok
  def flush(reason), do: call_owner({:flush, reason})

  @doc """
  Cache state for the telemetry poller: per-table sizes and memory,
  cumulative counters, in-flight loads, and whether the metadb is
  currently reachable (expiry pauses while it is not).
  """
  @spec stats() :: map()
  def stats do
    if enabled?(), do: GenServer.call(__MODULE__, :stats), else: %{}
  catch
    :exit, _reason -> %{}
  end

  @doc """
  Reads an entry without the read-through path — no load, no refresh, no
  counters. For tests and diagnostics: the public `fetch_*` functions
  repopulate on a miss and so cannot observe absence.
  """
  @spec peek(table(), String.t()) :: entry() | :absent
  def peek(table, key) do
    case :ets.lookup(table!(table), key) do
      [{^key, value, _loaded_at}] -> value
      [] -> :absent
    end
  end

  @doc """
  Inserts an entry with an explicit load time, so tests can age one into
  the refresh window or past its TTL without waiting. `loaded_at` is on
  the `System.monotonic_time(:millisecond)` scale.
  """
  @spec seed(table(), String.t(), entry(), integer()) :: :ok
  def seed(table, key, value, loaded_at) do
    call_owner({:seed, table, key, value, loaded_at})
  end

  @doc """
  The monotonic clock the cache stamps entries with — for tests building
  a `loaded_at` relative to now.
  """
  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)

  defp maybe_refresh(table, key, loaded_at) do
    %{refresh_after_ms: after_ms, refresh_jitter_ms: jitter} = runtime()

    if now_ms() - loaded_at >= after_ms + jitter(key, jitter) do
      bump(:refreshes)
      GenServer.cast(__MODULE__, {:refresh, table, key})
    end

    :ok
  end

  defp jitter(_key, 0), do: 0
  defp jitter(key, spread), do: :erlang.phash2(key, spread)

  defp load(table, key) do
    GenServer.call(__MODULE__, {:load, table, key}, runtime().load_timeout_ms)
  catch
    :exit, _reason ->
      bump(:load_timeouts)
      {:error, :metadb_unavailable}
  end

  defp call_owner(message) do
    if enabled?(), do: GenServer.call(__MODULE__, message), else: :ok
  catch
    :exit, reason ->
      Logger.warning("read model write dropped: #{inspect(reason)}")
      :ok
  end

  @impl true
  def init(opts) do
    {fetch, opts} = Keyword.pop(opts, :fetch, &Source.fetch/2)
    {probe, opts} = Keyword.pop(opts, :probe, &Source.ping/0)

    runtime = build_runtime(opts)
    :persistent_term.put({__MODULE__, :runtime}, runtime)

    for ets <- Map.values(@tables) do
      :ets.new(ets, [:set, :named_table, :protected, read_concurrency: true])
    end

    state = %{
      fetch: fetch,
      probe: probe,
      inflight: %{},
      load_keys: %{},
      metadb_ok?: true,
      runtime: runtime
    }

    schedule_sweep(state)
    {:ok, state}
  end

  defp build_runtime(opts) do
    config = @defaults |> Map.merge(Map.new(env_config())) |> Map.merge(Map.new(opts))

    Map.merge(config, %{
      refresh_after_ms: trunc(config.ttl_ms * config.refresh_ratio),
      counters: :counters.new(length(@counter_names), [:write_concurrency])
    })
  end

  @impl true
  def handle_call({:load, table, key}, from, state) do
    case peek(table, key) do
      :absent ->
        {:noreply, join_or_start_load(state, {table, key}, from)}

      value ->
        bump(:collapsed)
        {:reply, to_result(value), state}
    end
  end

  def handle_call({:put, table, key, row}, _from, state) do
    insert(table, key, {:ok, row})
    {:reply, :ok, invalidate(state, table, key)}
  end

  def handle_call({:replace_if_cached, table, key, row}, _from, state) do
    replace_if_present(table, key, {:ok, row})
    {:reply, :ok, invalidate(state, table, key)}
  end

  def handle_call({:delete, table, key}, _from, state) do
    replace_if_present(table, key, :missing)
    {:reply, :ok, invalidate(state, table, key)}
  end

  def handle_call({:truncate, table}, _from, state) do
    :ets.delete_all_objects(table!(table))
    {:reply, :ok, invalidate_table(state, table)}
  end

  def handle_call({:flush, reason}, _from, state) do
    for ets <- Map.values(@tables), do: :ets.delete_all_objects(ets)

    Logger.warning("read model flushed: #{reason}")
    Telemetry.read_model_flushed(reason)

    {:reply, :ok, invalidate_all(state)}
  end

  def handle_call({:seed, table, key, value, loaded_at}, _from, state) do
    :ets.insert(table!(table), {key, value, loaded_at})
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, build_stats(state), state}
  end

  @impl true
  def handle_cast({:refresh, table, key}, state) do
    k = {table, key}

    if Map.has_key?(state.inflight, k),
      do: {:noreply, state},
      else: {:noreply, start_load(state, k, [])}
  end

  @impl true
  def handle_info({:fetched, pid, result}, state) do
    {:noreply, finish_load(state, pid, result)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    if Map.has_key?(state.load_keys, pid) do
      Logger.error("read model load crashed: #{inspect(reason)}")
    end

    {:noreply, finish_load(state, pid, {:error, :metadb_unavailable})}
  end

  def handle_info(:sweep, state) do
    {expired, evicted} = sweep(state)

    if expired > 0 or evicted > 0 do
      bump(:expired, expired)
      bump(:evicted, evicted)
      Telemetry.read_model_sweep(expired, evicted)
    end

    start_probe(state)
    schedule_sweep(state)
    {:noreply, state}
  end

  def handle_info({:probe, result}, state) do
    {:noreply, %{state | metadb_ok?: result == :ok}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_load(state, {table, key} = k, waiters) do
    owner = self()
    fetch = state.fetch

    {pid, _ref} = spawn_monitor(fn -> send(owner, {:fetched, self(), fetch.(table, key)}) end)

    %{
      state
      | inflight: Map.put(state.inflight, k, %{waiters: waiters, invalidated?: false}),
        load_keys: Map.put(state.load_keys, pid, k)
    }
  end

  defp start_probe(state) do
    owner = self()
    probe = state.probe
    spawn(fn -> send(owner, {:probe, probe.()}) end)
    :ok
  end

  defp join_or_start_load(state, k, from) do
    case Map.fetch(state.inflight, k) do
      {:ok, load} ->
        bump(:collapsed)
        put_in(state.inflight[k], %{load | waiters: [from | load.waiters]})

      :error ->
        start_load(state, k, [from])
    end
  end

  defp finish_load(state, pid, result) do
    case Map.pop(state.load_keys, pid) do
      {nil, _load_keys} ->
        state

      {{table, key} = k, load_keys} ->
        {load, inflight} = Map.pop!(state.inflight, k)

        reply =
          if load.invalidated?, do: discard_load(table, key), else: cache(table, key, result)

        Enum.each(load.waiters, &GenServer.reply(&1, reply))

        %{
          state
          | inflight: inflight,
            load_keys: load_keys,
            metadb_ok?: result != {:error, :metadb_unavailable}
        }
    end
  end

  defp discard_load(table, key) do
    bump(:discarded)
    Telemetry.read_model_load_discarded(table)

    case peek(table, key) do
      {:ok, row} ->
        {:ok, row}

      :missing ->
        {:error, :not_found}

      :absent ->
        insert(table, key, :missing)
        {:error, :not_found}
    end
  end

  defp cache(table, key, {:ok, row}) do
    insert(table, key, {:ok, row})
    {:ok, row}
  end

  defp cache(table, key, {:error, :not_found}) do
    insert(table, key, :missing)
    {:error, :not_found}
  end

  defp cache(table, _key, {:error, :metadb_unavailable} = error) do
    bump(:load_failures)
    Telemetry.read_model_load_failed(table)
    error
  end

  defp to_result({:ok, row}), do: {:ok, row}
  defp to_result(:missing), do: {:error, :not_found}

  defp insert(table, key, value) do
    :ets.insert(table!(table), {key, value, now_ms()})
    :ok
  end

  defp replace_if_present(table, key, value) do
    if peek(table, key) != :absent, do: insert(table, key, value)
    :ok
  end

  defp invalidate(state, table, key) do
    case Map.fetch(state.inflight, {table, key}) do
      {:ok, load} -> put_in(state.inflight[{table, key}], %{load | invalidated?: true})
      :error -> state
    end
  end

  defp invalidate_table(state, table) do
    invalidate_matching(state, fn {t, _key} -> t == table end)
  end

  defp invalidate_all(state), do: invalidate_matching(state, fn _k -> true end)

  defp invalidate_matching(state, match_fun) do
    inflight =
      Map.new(state.inflight, fn {k, load} ->
        if match_fun.(k), do: {k, %{load | invalidated?: true}}, else: {k, load}
      end)

    %{state | inflight: inflight}
  end

  defp sweep(state) do
    Enum.reduce(Map.keys(@tables), {0, 0}, fn table, {expired, evicted} ->
      {expired + expire(table, state), evicted + evict_over_cap(table, state)}
    end)
  end

  defp expire(table, state) do
    ets = table!(table)
    now = now_ms()

    negatives =
      :ets.select_delete(ets, [
        {{:_, :missing, :"$1"}, [{:<, :"$1", now - state.runtime.negative_ttl_ms}], [true]}
      ])

    positives =
      if state.metadb_ok? do
        :ets.select_delete(ets, [
          {{:_, :"$1", :"$2"},
           [{:"/=", :"$1", :missing}, {:<, :"$2", now - state.runtime.ttl_ms}], [true]}
        ])
      else
        0
      end

    negatives + positives
  end

  defp evict_over_cap(table, state) do
    ets = table!(table)
    size = :ets.info(ets, :size)

    if size > state.runtime.max_entries do
      target = trunc(state.runtime.max_entries * (1 - state.runtime.evict_hysteresis))
      victims = size - target

      for {_rank, _loaded_at, key} <- eviction_victims(ets, victims), do: :ets.delete(ets, key)

      victims
    else
      0
    end
  end

  defp eviction_victims(ets, victims) do
    ets
    |> :ets.select([
      {{:"$1", :missing, :"$2"}, [], [{{0, :"$2", :"$1"}}]},
      {{:"$1", :"$2", :"$3"}, [{:"/=", :"$2", :missing}], [{{1, :"$3", :"$1"}}]}
    ])
    |> Enum.reduce(:gb_sets.empty(), fn entry, kept ->
      kept = :gb_sets.add(entry, kept)

      if :gb_sets.size(kept) > victims do
        :gb_sets.delete(:gb_sets.largest(kept), kept)
      else
        kept
      end
    end)
    |> :gb_sets.to_list()
  end

  defp build_stats(state) do
    tables =
      Map.new(@tables, fn {name, ets} ->
        {name, %{entries: :ets.info(ets, :size), memory_bytes: memory_bytes(ets)}}
      end)

    %{
      tables: tables,
      counters: counter_values(),
      inflight: map_size(state.inflight),
      metadb_ok?: state.metadb_ok?
    }
  end

  defp memory_bytes(ets), do: :ets.info(ets, :memory) * :erlang.system_info(:wordsize)

  defp counter_values do
    ref = runtime().counters
    Map.new(@counter_index, fn {name, index} -> {name, :counters.get(ref, index)} end)
  end

  defp bump(counter, amount \\ 1) do
    :counters.add(runtime().counters, Map.fetch!(@counter_index, counter), amount)
  end

  defp schedule_sweep(state) do
    Process.send_after(self(), :sweep, state.runtime.sweep_interval_ms)
  end

  defp runtime, do: :persistent_term.get({__MODULE__, :runtime})

  defp env_config do
    Application.get_env(:smolsqls, __MODULE__, []) |> Keyword.delete(:enabled)
  end

  defp key_for(table, %{token_hash: token_hash})
       when table in [:database_tokens, :tenant_api_keys],
       do: token_hash

  defp key_for(_table, %{id: id}), do: id

  defp table!(table), do: Map.fetch!(@tables, table)
end
