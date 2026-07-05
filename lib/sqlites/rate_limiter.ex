defmodule Sqlites.RateLimiter do
  @moduledoc """
  Fixed-window per-database rate limiting at the protocol edge. Counts
  live in a public ETS table keyed by `{database_id, second}`, so the
  check is one `update_counter` on the request path; the owning
  process only sweeps expired windows. Limits are per node — the edge
  a request lands on — which is the right budget for protecting a
  node's writer processes.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.seconds(10)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec allow?(String.t(), pos_integer() | nil) :: boolean()
  def allow?(_database_id, nil), do: true

  def allow?(database_id, rps) when is_integer(rps) and rps > 0 do
    key = {database_id, System.system_time(:second)}
    :ets.update_counter(@table, key, {2, 1}, {key, 0}) <= rps
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:second) - 5

    :ets.select_delete(@table, [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end
end
