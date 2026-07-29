defmodule Smolsqls.ReadModelSoakTest do
  @moduledoc """
  Randomized convergence check for the cache. Hand-enumerated
  interleavings (see `Smolsqls.ReadModelTest`) only cover the orderings
  we thought of; this one runs concurrent readers against a mutating
  store and asserts the invariant that matters:

  > the cache never holds a row the source of truth does not have.

  The run ends with a **drain phase**: entries are cleared so every
  reader starts a fresh load, then every row is deleted from the store
  while those loads are still out. A stale insert landing after its
  delete has nothing after it to paper it over. Loads are deliberately
  slow, and slow *after* reading the store — that is what models a read
  that returned a row which has since been deleted, and it is the only
  arrangement in which a stale insert can happen at all.

  Both the workload and the drain were validated by disabling in-flight
  invalidation and confirming the test fails — a mixed workload with an
  end-state check alone does not catch it, because the final state is
  dominated by each id's last mutation.

  The source of truth is a simulated store rather than Postgres, so
  convergence can be checked exactly and far more interleavings driven
  than a sandboxed Repo would allow. Randomness comes from the ExUnit
  seed, so a failure replays with `--seed`; `SOAK_ROUNDS` scales it up.
  """

  use ExUnit.Case, async: false

  alias Smolsqls.ControlPlane.Database
  alias Smolsqls.ReadModel
  alias Smolsqls.Wait

  @store __MODULE__.Store
  @readers 12
  @pool_size 24

  setup do
    :ets.new(@store, [:set, :named_table, :public, read_concurrency: true])

    fetch = fn :databases, id ->
      result =
        case :ets.lookup(@store, id) do
          [{^id, row}] -> {:ok, row}
          [] -> {:error, :not_found}
        end

      Process.sleep(:rand.uniform(6))
      result
    end

    start_supervised!(
      {ReadModel,
       fetch: fn table, key -> fetch.(table, key) end,
       probe: fn -> :ok end,
       sweep_interval_ms: 60_000,
       negative_ttl_ms: 5,
       max_entries: 1_000}
    )

    ids = for _ <- 1..@pool_size, do: Ecto.UUID.generate()
    for id <- ids, do: put_row(id)

    %{ids: ids, rounds: rounds(), seed: ExUnit.configuration()[:seed]}
  end

  defp rounds, do: System.get_env("SOAK_ROUNDS", "300") |> String.to_integer()

  defp put_row(id) do
    :ets.insert(@store, {id, %Database{id: id, tenant_id: Ecto.UUID.generate(), status: :active}})
  end

  defp store_row(id) do
    case :ets.lookup(@store, id) do
      [{^id, row}] -> row
      [] -> nil
    end
  end

  test "the cache holds nothing the store has dropped", %{ids: ids, rounds: rounds, seed: seed} do
    running = :counters.new(1, [])
    :counters.put(running, 1, 1)

    readers =
      for reader <- 1..@readers do
        Task.async(fn ->
          :rand.seed(:exsss, {seed + reader, seed, seed})
          read_until_stopped(running, ids, 0)
        end)
      end

    mutator =
      Task.async(fn ->
        :rand.seed(:exsss, {seed, seed + 1, seed})
        mutate(ids, rounds)
        drain(ids)
      end)

    Task.await(mutator, 120_000)
    :counters.put(running, 1, 0)
    Task.await_many(readers, 60_000)

    assert :ok == Wait.until(fn -> ReadModel.stats().inflight == 0 end, 400, 5)

    for id <- ids do
      case {store_row(id), ReadModel.peek(:databases, id)} do
        {nil, {:ok, cached}} -> flunk("cached #{cached.id}, which the store has dropped")
        {nil, _absent_or_missing} -> :ok
        {%Database{id: ^id}, {:ok, cached}} -> assert cached.id == id
        {%Database{}, _absent_or_missing} -> :ok
      end
    end
  end

  defp read_until_stopped(running, ids, reads) do
    if :counters.get(running, 1) == 1 do
      id = Enum.random(ids)

      case ReadModel.fetch(:databases, id) do
        {:ok, %Database{id: ^id}} -> :ok
        {:error, reason} when reason in [:not_found, :metadb_unavailable] -> :ok
      end

      read_until_stopped(running, ids, reads + 1)
    else
      reads
    end
  end

  defp mutate(ids, rounds) do
    for _ <- 1..rounds do
      id = Enum.random(ids)

      case :rand.uniform(3) do
        1 ->
          :ets.delete(@store, id)
          ReadModel.delete(:databases, id)

        2 ->
          put_row(id)
          ReadModel.replace_if_cached(:databases, store_row(id))

        3 ->
          put_row(id)
          ReadModel.put(:databases, store_row(id))
      end
    end
  end

  defp drain(ids) do
    for _pass <- 1..3 do
      for id <- ids, do: put_row(id)

      ReadModel.truncate(:databases)
      Process.sleep(2)

      for id <- Enum.shuffle(ids) do
        :ets.delete(@store, id)
        ReadModel.delete(:databases, id)
      end
    end
  end
end
