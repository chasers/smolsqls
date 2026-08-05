defmodule Smolsqls.DataPlane.ChangeStream do
  @moduledoc """
  Cluster-wide fanout of row-change events from a database's write
  path to live subscribers, backed by a `:syn` process group per
  database.

  `Smolsqls.DataPlane.Database.Server` captures changes through
  SQLite's update hook and publishes here only when the database has
  at least one subscriber (`subscriber_count/1` is a cheap local ETS
  lookup), so idle databases pay nothing.

  Subscribers receive `{:smolsqls_change, database_id, event}`
  messages. Delivery to remote subscribers rides Erlang distribution
  (`:syn.publish/3`) — events are small, unlike query payloads, which
  deliberately stay off distribution.
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
    :syn.join(@scope, database_id, self())
  end

  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(database_id) do
    :syn.leave(@scope, database_id, self())
  end

  @spec subscriber_count(String.t()) :: non_neg_integer()
  def subscriber_count(database_id) do
    :syn.member_count(@scope, database_id)
  end

  @spec publish(String.t(), event()) :: :ok
  def publish(database_id, event) do
    {:ok, _count} = :syn.publish(@scope, database_id, {:smolsqls_change, database_id, event})
    :ok
  end
end
