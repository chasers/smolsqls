defmodule Smolsqls.ExpirySweeper do
  @moduledoc """
  Cluster singleton that deletes ephemeral databases once their
  `expires_at` has passed — the reaper behind branch TTLs.

  On each tick a single node — chosen by a Postgres advisory lock, so
  exactly one sweep runs cluster-wide — lists the databases whose
  `expires_at` is in the past and removes each through
  `Smolsqls.remove_database/1` (row, tokens, object-store artifacts, and
  local files). A database that has since accrued its own branches is
  skipped (logged) until those are gone, honouring the
  no-delete-while-branched guard; it is retried on the next tick.
  `:batch_size` bounds how many a single tick handles.

  Started on every node but gated by `enabled: true`; the advisory lock
  makes running it everywhere safe.
  """

  use GenServer

  require Logger

  alias Smolsqls.ControlPlane
  alias Smolsqls.Repo

  @advisory_lock_key 5_142_004

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    schedule_sweep(initial_delay())
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep(interval())
    {:noreply, state}
  end

  @doc """
  Runs one sweep if this node wins the advisory lock; otherwise a no-op.
  Returns the number of databases deleted (0 when not the leader).
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    as_leader(fn ->
      now = DateTime.utc_now()
      due = ControlPlane.due_for_expiry(now, limit: batch_size())
      deleted = Enum.count(due, &(expire(&1) == :ok))

      if due != [] do
        Logger.info("expiry sweeper: #{deleted}/#{length(due)} expired database(s) deleted")
      end

      deleted
    end) || 0
  end

  defp expire(database) do
    case Smolsqls.remove_database(database) do
      {:ok, _} ->
        :ok

      {:error, :has_branches} ->
        Logger.info("expiry sweeper: #{database.id} expired but has branches; deferring")
        :error

      {:error, reason} ->
        Logger.warning("expiry sweeper: delete of #{database.id} failed: #{inspect(reason)}")
        :error
    end
  end

  defp as_leader(fun) do
    Repo.checkout(fn ->
      case Repo.query!("SELECT pg_try_advisory_lock($1)", [@advisory_lock_key]) do
        %{rows: [[true]]} ->
          try do
            fun.()
          after
            Repo.query!("SELECT pg_advisory_unlock($1)", [@advisory_lock_key])
          end

        _ ->
          nil
      end
    end)
  end

  defp schedule_sweep(delay), do: Process.send_after(self(), :sweep, delay)

  defp config, do: Application.get_env(:smolsqls, __MODULE__, [])
  defp interval, do: config()[:interval] || :timer.minutes(10)
  defp initial_delay, do: config()[:initial_delay] || :timer.minutes(1)
  defp batch_size, do: config()[:batch_size] || 500
end
