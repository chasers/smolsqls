defmodule Smolsqls.DataPlane.ChangeStream do
  @moduledoc """
  Cluster-wide fanout of row-change events from a database's write
  path to live subscribers.

  Delivery rides `Phoenix.PubSub` (the `Smolsqls.PubSub` server) on a
  topic per database. Subscribers are tracked with `Phoenix.Presence`
  (`Smolsqls.DataPlane.ChangeStream.Presence`) on a companion topic —
  separate so presence-diff broadcasts never land in subscriber
  mailboxes — whose ETS-mirrored count lets
  `Smolsqls.DataPlane.Database.Server` skip capture work entirely on
  databases nobody is watching: one lock-free ETS read per changed
  row. `:syn` plays no part here; it tracks database server processes
  only.

  Subscribers receive `{:smolsqls_change, database_id, event}`
  messages. Presence counts are eventually consistent, so events
  written in the instant between subscribing and the count
  propagating may be missed — a subscription is a live tap, not a
  consistent snapshot point. Cross-node delivery goes over Erlang
  distribution — events are small, unlike query payloads, which
  deliberately stay off distribution.
  """

  alias Smolsqls.DataPlane.ChangeStream.Presence

  @type event :: %{
          action: :insert | :update | :delete,
          table: String.t(),
          rowid: integer(),
          record: %{String.t() => term()} | nil
        }

  @doc """
  Subscribes the calling process to a database's change events. The
  subscription is cleaned up automatically when the process exits.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(database_id) do
    with :ok <- Phoenix.PubSub.subscribe(Smolsqls.PubSub, topic(database_id)),
         {:ok, _ref} <-
           Presence.track(self(), presence_topic(database_id), inspect(self()), %{}) do
      :ok
    end
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(database_id) do
    :ok = Presence.untrack(self(), presence_topic(database_id), inspect(self()))
    Phoenix.PubSub.unsubscribe(Smolsqls.PubSub, topic(database_id))
  end

  @spec subscriber_count(String.t()) :: non_neg_integer()
  def subscriber_count(database_id) do
    Presence.count(presence_topic(database_id))
  end

  @spec publish(String.t(), event()) :: :ok
  def publish(database_id, event) do
    :ok =
      Phoenix.PubSub.broadcast(
        Smolsqls.PubSub,
        topic(database_id),
        {:smolsqls_change, database_id, event}
      )
  end

  defp topic(database_id), do: "change_stream:" <> database_id

  defp presence_topic(database_id), do: "change_stream_presence:" <> database_id
end
