defmodule Smolsqls.ReadModelTest do
  @moduledoc """
  The cache mechanics, driven through an injected fetch function so
  every interleaving is a handshake rather than a timing window. No
  `Process.sleep/1` for ordering: a sleep-based version of these tests
  passes locally, flakes in CI, and silently stops exercising the race
  once timings shift.
  """

  use ExUnit.Case, async: false

  alias Smolsqls.ControlPlane.{Database, DatabaseToken, Tenant}
  alias Smolsqls.ReadModel
  alias Smolsqls.Wait

  setup do
    test = self()
    counter = :counters.new(1, [])

    fetch = fn table, key ->
      :counters.add(counter, 1, 1)
      send(test, {:fetch, table, key, self()})

      receive do
        {:return, value} -> value
      end
    end

    start_cache = fn opts ->
      opts =
        opts
        |> Keyword.put_new(:fetch, fetch)
        |> Keyword.put_new(:probe, fn -> :ok end)
        |> Keyword.put_new(:sweep_interval_ms, 60_000)
        |> Keyword.put_new(:refresh_jitter_ms, 0)
        |> Keyword.put_new(:load_timeout_ms, 2_000)

      start_supervised!({ReadModel, opts})
    end

    start_cache.([])

    %{counter: counter, start_cache: start_cache}
  end

  defp fetch_count(counter), do: :counters.get(counter, 1)

  defp database(overrides \\ %{}) do
    struct!(
      %Database{id: Ecto.UUID.generate(), tenant_id: Ecto.UUID.generate(), status: :active},
      overrides
    )
  end

  defp token(overrides \\ %{}) do
    struct!(
      %DatabaseToken{
        id: Ecto.UUID.generate(),
        database_id: Ecto.UUID.generate(),
        token_hash: Smolsqls.Secrets.hash("tok-#{System.unique_integer([:positive])}"),
        enabled: true
      },
      overrides
    )
  end

  defp reader(table, key), do: Task.async(fn -> ReadModel.fetch(table, key) end)

  defp cache_now(table, row), do: :ok = ReadModel.put(table, row)

  defp sweep_now do
    send(ReadModel, :sweep)
    ReadModel.stats()
  end

  describe "hits" do
    test "a cached row is served without reading the metadb", %{counter: counter} do
      db = database()
      cache_now(:databases, db)

      assert {:ok, %Database{}} = ReadModel.fetch(:databases, db.id)
      assert fetch_count(counter) == 0
    end

    test "an invalid key is answered without reading the metadb", %{counter: counter} do
      assert ReadModel.fetch(:databases, "not-a-uuid") == {:error, :not_found}
      assert ReadModel.fetch(:tenants, "") == {:error, :not_found}
      assert fetch_count(counter) == 0
      assert ReadModel.peek(:databases, "not-a-uuid") == :absent
    end
  end

  describe "read-through" do
    test "a miss loads the row, caches it, and answers the waiter" do
      db = database()
      task = reader(:databases, db.id)

      assert_receive {:fetch, :databases, key, fetcher}
      assert key == db.id
      send(fetcher, {:return, {:ok, db}})

      assert {:ok, loaded} = Task.await(task)
      assert loaded.id == db.id
      assert ReadModel.peek(:databases, db.id) == {:ok, db}
    end

    test "a row that does not exist is cached as missing and not re-read", %{counter: counter} do
      id = Ecto.UUID.generate()
      task = reader(:databases, id)

      assert_receive {:fetch, :databases, ^id, fetcher}
      send(fetcher, {:return, {:error, :not_found}})

      assert Task.await(task) == {:error, :not_found}
      assert ReadModel.peek(:databases, id) == :missing

      assert ReadModel.fetch(:databases, id) == {:error, :not_found}
      assert fetch_count(counter) == 1
    end

    test "an unreachable metadb is reported, not cached, and not an auth failure" do
      id = Ecto.UUID.generate()
      task = reader(:databases, id)

      assert_receive {:fetch, :databases, ^id, fetcher}
      send(fetcher, {:return, {:error, :metadb_unavailable}})

      assert Task.await(task) == {:error, :metadb_unavailable}
      assert ReadModel.peek(:databases, id) == :absent
      refute ReadModel.stats().metadb_ok?
    end

    test "concurrent misses on one key collapse into a single load", %{counter: counter} do
      db = database()
      tasks = for _ <- 1..25, do: reader(:databases, db.id)

      assert_receive {:fetch, :databases, _key, fetcher}
      send(fetcher, {:return, {:ok, db}})

      assert tasks |> Enum.map(&Task.await/1) |> Enum.uniq() == [{:ok, db}]
      assert fetch_count(counter) == 1

      counters = ReadModel.stats().counters
      assert counters.collapsed + counters.hits == 24
    end

    test "tokens are keyed by hash" do
      tok = token()
      task = reader(:database_tokens, tok.token_hash)

      assert_receive {:fetch, :database_tokens, hash, fetcher}
      assert hash == tok.token_hash
      send(fetcher, {:return, {:ok, tok}})

      assert {:ok, %DatabaseToken{}} = Task.await(task)
      assert ReadModel.peek(:database_tokens, tok.token_hash) == {:ok, tok}
    end
  end

  describe "refresh-ahead" do
    test "a hit past the threshold serves the cached row and reloads behind it" do
      db = database(%{node: "old@node"})
      fresh = %{db | node: "new@node"}

      ReadModel.seed(:databases, db.id, {:ok, db}, ReadModel.now_ms() - :timer.hours(13))

      assert {:ok, %{node: "old@node"}} = ReadModel.fetch(:databases, db.id)

      assert_receive {:fetch, :databases, key, fetcher}
      assert key == db.id
      send(fetcher, {:return, {:ok, fresh}})

      assert :ok == Wait.until(fn -> ReadModel.peek(:databases, db.id) == {:ok, fresh} end)
    end

    test "a hit inside the threshold does not reload", %{counter: counter} do
      db = database()
      ReadModel.seed(:databases, db.id, {:ok, db}, ReadModel.now_ms() - :timer.hours(11))

      assert {:ok, _row} = ReadModel.fetch(:databases, db.id)
      assert fetch_count(counter) == 0
    end

    test "a failed refresh leaves the entry in place" do
      db = database()
      ReadModel.seed(:databases, db.id, {:ok, db}, ReadModel.now_ms() - :timer.hours(13))

      assert {:ok, _row} = ReadModel.fetch(:databases, db.id)
      assert_receive {:fetch, :databases, _key, fetcher}
      send(fetcher, {:return, {:error, :metadb_unavailable}})

      assert :ok == Wait.until(fn -> ReadModel.stats().metadb_ok? == false end)
      assert ReadModel.peek(:databases, db.id) == {:ok, db}
    end

    test "a refresh finding the row gone replaces it with a negative entry" do
      db = database()
      ReadModel.seed(:databases, db.id, {:ok, db}, ReadModel.now_ms() - :timer.hours(13))

      assert {:ok, _row} = ReadModel.fetch(:databases, db.id)
      assert_receive {:fetch, :databases, _key, fetcher}
      send(fetcher, {:return, {:error, :not_found}})

      assert :ok == Wait.until(fn -> ReadModel.peek(:databases, db.id) == :missing end)
    end
  end

  describe "a mutation arriving while a load is in flight" do
    test "a delete discards the stale result the load was about to cache" do
      db = database()
      attach_telemetry([:smolsqls, :read_model, :load_discarded])

      task = reader(:databases, db.id)
      assert_receive {:fetch, :databases, _key, fetcher}

      :ok = ReadModel.delete(:databases, db.id)
      send(fetcher, {:return, {:ok, db}})

      assert Task.await(task) == {:error, :not_found}

      assert_receive {:telemetry, [:smolsqls, :read_model, :load_discarded], %{count: 1},
                      %{table: "databases"}}

      assert ReadModel.peek(:databases, db.id) == :missing
      assert ReadModel.stats().counters.discarded == 1
    end

    test "a delete before the load starts still ends with nothing cached" do
      db = database()

      :ok = ReadModel.delete(:databases, db.id)
      assert ReadModel.peek(:databases, db.id) == :absent

      task = reader(:databases, db.id)
      assert_receive {:fetch, :databases, _key, fetcher}
      send(fetcher, {:return, {:error, :not_found}})

      assert Task.await(task) == {:error, :not_found}
      assert ReadModel.peek(:databases, db.id) == :missing
    end

    test "a write-through discards the stale result and keeps the fresher row" do
      db = database(%{node: "stale@node"})
      fresh = %{db | node: "fresh@node"}

      task = reader(:databases, db.id)
      assert_receive {:fetch, :databases, _key, fetcher}

      cache_now(:databases, fresh)
      send(fetcher, {:return, {:ok, db}})

      assert {:ok, %{node: "fresh@node"}} = Task.await(task)
      assert ReadModel.peek(:databases, db.id) == {:ok, fresh}
    end

    test "a truncate discards every in-flight load for the table" do
      one = database()
      two = database()

      task_one = reader(:databases, one.id)
      task_two = reader(:databases, two.id)

      assert_receive {:fetch, :databases, _key, fetcher_one}
      assert_receive {:fetch, :databases, _key, fetcher_two}

      :ok = ReadModel.truncate(:databases)
      send(fetcher_one, {:return, {:ok, one}})
      send(fetcher_two, {:return, {:ok, two}})

      assert Task.await(task_one) == {:error, :not_found}
      assert Task.await(task_two) == {:error, :not_found}
      assert ReadModel.peek(:databases, one.id) == :missing
      assert ReadModel.peek(:databases, two.id) == :missing
    end

    test "a flush discards in-flight loads across every table" do
      db = database()
      tok = token()

      db_task = reader(:databases, db.id)
      token_task = reader(:database_tokens, tok.token_hash)

      assert_receive {:fetch, :databases, _key, db_fetcher}
      assert_receive {:fetch, :database_tokens, _key, token_fetcher}

      :ok = ReadModel.flush(:slot_invalidated)
      send(db_fetcher, {:return, {:ok, db}})
      send(token_fetcher, {:return, {:ok, tok}})

      assert Task.await(db_task) == {:error, :not_found}
      assert Task.await(token_task) == {:error, :not_found}
    end

    test "every waiter on a discarded load sees the miss" do
      db = database()
      tasks = for _ <- 1..25, do: reader(:databases, db.id)

      assert_receive {:fetch, :databases, _key, fetcher}
      :ok = ReadModel.delete(:databases, db.id)
      send(fetcher, {:return, {:ok, db}})

      assert tasks |> Enum.map(&Task.await/1) |> Enum.uniq() == [{:error, :not_found}]
    end

    test "the guard is not a blanket refusal to cache, and it releases the key" do
      discarded = database()
      other = database()

      task = reader(:databases, discarded.id)
      assert_receive {:fetch, :databases, _key, fetcher}
      :ok = ReadModel.delete(:databases, discarded.id)
      send(fetcher, {:return, {:ok, discarded}})
      assert Task.await(task) == {:error, :not_found}

      assert ReadModel.stats().inflight == 0

      other_task = reader(:databases, other.id)
      assert_receive {:fetch, :databases, _key, other_fetcher}
      send(other_fetcher, {:return, {:ok, other}})
      assert {:ok, _row} = Task.await(other_task)
      assert ReadModel.peek(:databases, other.id) == {:ok, other}
    end

    test "a feed insert clears a negative entry left by a discard" do
      db = database()

      task = reader(:databases, db.id)
      assert_receive {:fetch, :databases, _key, fetcher}
      :ok = ReadModel.delete(:databases, db.id)
      send(fetcher, {:return, {:ok, db}})
      assert Task.await(task) == {:error, :not_found}
      assert ReadModel.peek(:databases, db.id) == :missing

      :ok = ReadModel.replace_if_cached(:databases, db)
      assert ReadModel.peek(:databases, db.id) == {:ok, db}
    end
  end

  describe "the WAL feed never populates" do
    test "merge is ignored for a key this node does not hold" do
      db = database()
      :ok = ReadModel.replace_if_cached(:databases, db)
      assert ReadModel.peek(:databases, db.id) == :absent
    end

    test "merge replaces a held row" do
      db = database(%{node: nil})
      cache_now(:databases, db)

      :ok = ReadModel.replace_if_cached(:databases, %{db | node: "claimed@somewhere"})
      assert {:ok, %{node: "claimed@somewhere"}} = ReadModel.peek(:databases, db.id)
    end

    test "merge replaces a held negative entry, so a create is not shadowed" do
      db = database()
      ReadModel.seed(:databases, db.id, :missing, ReadModel.now_ms())

      :ok = ReadModel.replace_if_cached(:databases, db)
      assert ReadModel.peek(:databases, db.id) == {:ok, db}
    end

    test "delete leaves a negative entry when the key was held, and nothing when it was not" do
      held = database()
      cache_now(:databases, held)

      :ok = ReadModel.delete(:databases, held.id)
      assert ReadModel.peek(:databases, held.id) == :missing

      unheld = database()
      :ok = ReadModel.delete(:databases, unheld.id)
      assert ReadModel.peek(:databases, unheld.id) == :absent
    end

    test "a token revocation drops the cached token" do
      tok = token()
      cache_now(:database_tokens, tok)

      :ok = ReadModel.replace_if_cached(:database_tokens, %{tok | enabled: false})
      assert {:ok, %{enabled: false}} = ReadModel.peek(:database_tokens, tok.token_hash)

      :ok = ReadModel.delete(:database_tokens, tok.token_hash)
      assert ReadModel.peek(:database_tokens, tok.token_hash) == :missing
    end

    test "flush drops every table" do
      db = database()
      tok = token()
      tenant = %Tenant{id: Ecto.UUID.generate(), limits: %{}}

      cache_now(:databases, db)
      cache_now(:database_tokens, tok)
      cache_now(:tenants, tenant)

      :ok = ReadModel.flush(:slot_invalidated)

      assert ReadModel.peek(:databases, db.id) == :absent
      assert ReadModel.peek(:database_tokens, tok.token_hash) == :absent
      assert ReadModel.peek(:tenants, tenant.id) == :absent
    end
  end

  describe "the sweeper" do
    test "expires entries past the TTL and keeps the rest", %{start_cache: start_cache} do
      stop_supervised!(ReadModel)
      start_cache.(ttl_ms: 1_000, negative_ttl_ms: 100)

      old = database()
      recent = database()
      ReadModel.seed(:databases, old.id, {:ok, old}, ReadModel.now_ms() - 5_000)
      ReadModel.seed(:databases, recent.id, {:ok, recent}, ReadModel.now_ms())

      sweep_now()

      assert ReadModel.peek(:databases, old.id) == :absent
      assert ReadModel.peek(:databases, recent.id) == {:ok, recent}
    end

    test "negative entries expire on the shorter negative TTL", %{start_cache: start_cache} do
      stop_supervised!(ReadModel)
      start_cache.(ttl_ms: :timer.hours(24), negative_ttl_ms: 100)

      id = Ecto.UUID.generate()
      ReadModel.seed(:databases, id, :missing, ReadModel.now_ms() - 1_000)

      sweep_now()
      assert ReadModel.peek(:databases, id) == :absent
    end

    test "expiry pauses while the metadb is unreachable", %{start_cache: start_cache} do
      stop_supervised!(ReadModel)
      start_cache.(ttl_ms: 1_000, negative_ttl_ms: 100)

      db = database()
      id = Ecto.UUID.generate()

      task = reader(:databases, Ecto.UUID.generate())
      assert_receive {:fetch, :databases, _key, fetcher}
      send(fetcher, {:return, {:error, :metadb_unavailable}})
      assert Task.await(task) == {:error, :metadb_unavailable}

      ReadModel.seed(:databases, db.id, {:ok, db}, ReadModel.now_ms() - 5_000)
      ReadModel.seed(:databases, id, :missing, ReadModel.now_ms() - 5_000)

      stats = sweep_now()
      refute stats.metadb_ok?

      assert ReadModel.peek(:databases, db.id) == {:ok, db}
      assert ReadModel.peek(:databases, id) == :absent
    end

    test "over the cap, negative entries go first, then the oldest rows",
         %{start_cache: start_cache} do
      stop_supervised!(ReadModel)
      start_cache.(max_entries: 4, evict_hysteresis: 0.0, ttl_ms: :timer.hours(24))

      now = ReadModel.now_ms()
      oldest = database()
      newer = database()
      newest = database()
      negative_one = Ecto.UUID.generate()
      negative_two = Ecto.UUID.generate()

      ReadModel.seed(:databases, negative_one, :missing, now - 10)
      ReadModel.seed(:databases, negative_two, :missing, now - 9)
      ReadModel.seed(:databases, oldest.id, {:ok, oldest}, now - 8)
      ReadModel.seed(:databases, newer.id, {:ok, newer}, now - 7)
      ReadModel.seed(:databases, newest.id, {:ok, newest}, now - 6)

      sweep_now()

      assert ReadModel.peek(:databases, negative_one) == :absent
      assert ReadModel.peek(:databases, oldest.id) == {:ok, oldest}
      assert ReadModel.peek(:databases, newer.id) == {:ok, newer}
      assert ReadModel.peek(:databases, newest.id) == {:ok, newest}
      assert :ets.info(ReadModel.Databases, :size) == 4
    end

    test "eviction still runs while the metadb is unreachable", %{start_cache: start_cache} do
      stop_supervised!(ReadModel)
      start_cache.(max_entries: 1, evict_hysteresis: 0.0, ttl_ms: :timer.hours(24))

      task = reader(:databases, Ecto.UUID.generate())
      assert_receive {:fetch, :databases, _key, fetcher}
      send(fetcher, {:return, {:error, :metadb_unavailable}})
      assert Task.await(task) == {:error, :metadb_unavailable}

      now = ReadModel.now_ms()
      one = database()
      two = database()
      ReadModel.seed(:databases, one.id, {:ok, one}, now - 100)
      ReadModel.seed(:databases, two.id, {:ok, two}, now)

      stats = sweep_now()
      refute stats.metadb_ok?
      assert :ets.info(ReadModel.Databases, :size) == 1
      assert ReadModel.peek(:databases, two.id) == {:ok, two}
    end
  end

  describe "stats" do
    test "reports entries, counters, and in-flight loads" do
      db = database()
      cache_now(:databases, db)
      assert {:ok, _row} = ReadModel.fetch(:databases, db.id)

      task = reader(:databases, Ecto.UUID.generate())
      assert_receive {:fetch, :databases, _key, fetcher}

      stats = ReadModel.stats()
      assert stats.tables.databases.entries == 1
      assert stats.tables.databases.memory_bytes > 0
      assert stats.counters.hits == 1
      assert stats.counters.misses == 1
      assert stats.inflight == 1

      send(fetcher, {:return, {:error, :not_found}})
      assert Task.await(task) == {:error, :not_found}
    end
  end

  defp attach_telemetry(event) do
    test = self()
    handler = {__MODULE__, event, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      event,
      fn name, measurements, metadata, _config ->
        send(test, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
