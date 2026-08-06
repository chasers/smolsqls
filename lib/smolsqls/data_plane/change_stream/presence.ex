defmodule Smolsqls.DataPlane.ChangeStream.Presence do
  @moduledoc """
  Tracks change-stream subscribers per database topic via
  `Phoenix.Presence`, and mirrors each topic's subscriber count into a
  public ETS table through `handle_metas/4`.

  The ETS mirror exists because the write path asks "does anyone
  care?" once per changed row: `Phoenix.Presence.list/1` is a
  `GenServer.call` into a tracker shard, which would serialize every
  database server through one process, while `count/1` here is a
  lock-free ETS read. Counts are eventually consistent — a presence
  join propagates to the table (and to other nodes) moments after
  `track/3` returns, so writes racing a brand-new subscription can
  still be skipped.
  """

  use Phoenix.Presence,
    otp_app: :smolsqls,
    pubsub_server: Smolsqls.PubSub

  @counts __MODULE__.Counts

  @impl true
  def init(_opts) do
    :ets.new(@counts, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_metas(topic, _diff, presences, state) do
    case map_size(presences) do
      0 -> :ets.delete(@counts, topic)
      count -> :ets.insert(@counts, {topic, count})
    end

    {:ok, state}
  end

  @spec count(String.t()) :: non_neg_integer()
  def count(topic) do
    case :ets.lookup(@counts, topic) do
      [{^topic, count}] -> count
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end
end
