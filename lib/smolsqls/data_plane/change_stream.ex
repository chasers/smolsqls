defmodule Smolsqls.DataPlane.ChangeStream do
  @moduledoc """
  Cluster-wide fanout of row-change events from a database's write
  path to live subscribers.

  Delivery rides `Phoenix.PubSub` (the `Smolsqls.PubSub` server) on a
  topic per database. A `:syn` process group mirrors the subscriber
  set purely for presence counting — `Phoenix.PubSub` cannot answer
  "does anyone care?", and `Smolsqls.DataPlane.Database.Server` uses
  `subscriber_count/1` (a cheap local ETS lookup) to skip capture work
  entirely on databases nobody is watching.

  Subscribers receive `{:smolsqls_change, database_id, event}`
  messages. Cross-node delivery goes over Erlang distribution — events
  are small, unlike query payloads, which deliberately stay off
  distribution.
  """

  @scope :smolsqls_change_streams

  @type event :: %{
          action: :insert | :update | :delete,
          table: String.t(),
          rowid: integer(),
          record: %{String.t() => term()} | nil
        }

  def scope, do: @scope

  def init do
    :syn.add_node_to_scopes([@scope])
  end

  @doc """
  Subscribes the calling process to a database's change events. The
  subscription is cleaned up automatically when the process exits.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(database_id) do
    with :ok <- Phoenix.PubSub.subscribe(Smolsqls.PubSub, topic(database_id)) do
      :syn.join(@scope, database_id, self())
    end
  end

  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(database_id) do
    :ok = Phoenix.PubSub.unsubscribe(Smolsqls.PubSub, topic(database_id))
    :syn.leave(@scope, database_id, self())
  end

  @spec subscriber_count(String.t()) :: non_neg_integer()
  def subscriber_count(database_id) do
    :syn.member_count(@scope, database_id)
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
end
