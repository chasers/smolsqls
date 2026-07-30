defmodule Smolsqls.ReadModel.Replication do
  @moduledoc """
  Streams the metadb WAL into the read model over a **permanent**
  logical replication slot named after this node — exact LSN continuity
  across reconnects, so nothing is ever missed. WAL retention while a
  node is down is capped by Postgres' `max_slot_wal_keep_size`; the
  operator drops a node's slot when the node is decommissioned.

  Changes made on other nodes arrive here. Inserts and updates only
  *replace rows this node already holds* (`ReadModel.replace_if_cached/2`) so the
  feed can never grow the cache toward a full replica; deletes always
  apply, so a revocation or a database removal takes effect immediately
  on every node caching it.

  If Postgres reports the slot missing or invalidated — the WAL it needed
  is gone, so deletes have been lost — the slot is recreated and the
  cache flushed. Strictly in that order: the flush repopulates through
  read-throughs immediately, so the new slot must already exist to
  capture any delete that follows — flushing first would leave a window
  where a row is cached and its delete falls between the two slots,
  keeping it alive for a full TTL. Flushing rather than resnapshotting
  is the whole benefit of a cache: correctness costs one drop, and the
  read-through path refills what is still being used.
  """

  use Postgrex.ReplicationConnection

  require Logger

  alias Smolsqls.ReadModel
  alias Smolsqls.ReadModel.{Pgoutput, Row}

  @publication "smolsqls_read_model"
  @invalidated_codes [:undefined_object, :object_not_in_prerequisite_state]

  def start_link(opts) do
    conn_opts =
      Application.fetch_env!(:smolsqls, Smolsqls.Repo)
      |> Keyword.take([:hostname, :username, :password, :database, :port])
      |> Keyword.merge(auto_reconnect: true)
      |> Keyword.merge(opts)

    Postgrex.ReplicationConnection.start_link(__MODULE__, slot_name(), conn_opts)
  end

  @spec slot_name() :: String.t()
  def slot_name do
    name =
      Node.self()
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")

    String.slice("smolsqls_" <> name, 0, 63)
  end

  @impl true
  def init(slot) do
    {:ok, %{slot: slot, step: :disconnected, relations: %{}, last_lsn: 0}}
  end

  @impl true
  def handle_connect(state) do
    {:query, create_slot_query(state), %{state | step: :create_slot}}
  end

  @impl true
  def handle_result(results, %{step: :create_slot} = state) when is_list(results) do
    start_streaming(state)
  end

  def handle_result(results, %{step: :drop_slot} = state) when is_list(results) do
    {:query, create_slot_query(state), %{state | step: :recreate_slot}}
  end

  def handle_result(results, %{step: :recreate_slot} = state) when is_list(results) do
    ReadModel.flush(:slot_invalidated)
    start_streaming(state)
  end

  def handle_result(
        %Postgrex.Error{postgres: %{code: :duplicate_object}},
        %{step: :create_slot} = state
      ) do
    start_streaming(state)
  end

  def handle_result(
        %Postgrex.Error{postgres: %{code: :duplicate_object}},
        %{step: :recreate_slot} = state
      ) do
    ReadModel.flush(:slot_invalidated)
    start_streaming(state)
  end

  def handle_result(
        %Postgrex.Error{postgres: %{code: :undefined_object}},
        %{step: :drop_slot} = state
      ) do
    {:query, create_slot_query(state), %{state | step: :recreate_slot}}
  end

  def handle_result(%Postgrex.Error{postgres: %{code: code}} = error, state)
      when code in @invalidated_codes and state.step != :drop_slot do
    Logger.error("read model slot #{state.slot} unusable: #{Exception.message(error)}")

    {:query, "DROP_REPLICATION_SLOT #{state.slot} WAIT", %{state | step: :drop_slot}}
  end

  def handle_result(%Postgrex.Error{} = error, state) do
    Logger.error("read model replication error: #{Exception.message(error)}")
    {:noreply, state}
  end

  defp create_slot_query(state) do
    "CREATE_REPLICATION_SLOT #{state.slot} LOGICAL pgoutput NOEXPORT_SNAPSHOT"
  end

  defp start_streaming(state) do
    query =
      "START_REPLICATION SLOT #{state.slot} LOGICAL 0/0 " <>
        "(proto_version '1', publication_names '#{@publication}')"

    {:stream, query, [], %{state | step: :streaming}}
  end

  @impl true
  def handle_data(<<?w, _start::64, _end::64, _clock::64, message::binary>>, state) do
    {event, relations} = Pgoutput.decode(message, state.relations)
    state = apply_event(event, %{state | relations: relations})
    {:noreply, state}
  end

  def handle_data(<<?k, wal_end::64, _clock::64, reply>>, state) do
    messages =
      case reply do
        1 -> [standby_status(max(state.last_lsn, wal_end))]
        0 -> []
      end

    {:noreply, messages, state}
  end

  def handle_data(_data, state), do: {:noreply, state}

  defp apply_event({:commit, end_lsn}, state), do: %{state | last_lsn: end_lsn}

  defp apply_event({change, "databases", values}, state) when change in [:insert, :update] do
    ReadModel.replace_if_cached(:databases, Row.build_database(values))
    state
  end

  defp apply_event({:delete, "databases", %{"id" => id}}, state) when is_binary(id) do
    ReadModel.delete(:databases, id)
    state
  end

  defp apply_event({change, "tenants", values}, state) when change in [:insert, :update] do
    ReadModel.replace_if_cached(:tenants, Row.build_tenant(values))
    state
  end

  defp apply_event({:delete, "tenants", %{"id" => id}}, state) when is_binary(id) do
    ReadModel.delete(:tenants, id)
    state
  end

  defp apply_event({change, "database_tokens", values}, state)
       when change in [:insert, :update] do
    ReadModel.replace_if_cached(:database_tokens, Row.build_database_token(values))
    state
  end

  defp apply_event({:delete, "database_tokens", %{"token_hash" => hash}}, state)
       when is_binary(hash) do
    ReadModel.delete(:database_tokens, hash)
    state
  end

  defp apply_event({:delete, "database_tokens", _values}, state) do
    warn_missing_hash("database_tokens")
    ReadModel.truncate(:database_tokens)
    state
  end

  defp apply_event({change, "tenant_api_keys", values}, state)
       when change in [:insert, :update] do
    ReadModel.replace_if_cached(:tenant_api_keys, Row.build_tenant_api_key(values))
    state
  end

  defp apply_event({:delete, "tenant_api_keys", %{"token_hash" => hash}}, state)
       when is_binary(hash) do
    ReadModel.delete(:tenant_api_keys, hash)
    state
  end

  defp apply_event({:delete, "tenant_api_keys", _values}, state) do
    warn_missing_hash("tenant_api_keys")
    ReadModel.truncate(:tenant_api_keys)
    state
  end

  defp apply_event({:truncate, names}, state) do
    for name <- names, table = cache_table(name), do: ReadModel.truncate(table)
    state
  end

  defp apply_event(_event, state), do: state

  defp cache_table("databases"), do: :databases
  defp cache_table("tenants"), do: :tenants
  defp cache_table("database_tokens"), do: :database_tokens
  defp cache_table("tenant_api_keys"), do: :tenant_api_keys
  defp cache_table(_other), do: nil

  defp warn_missing_hash(table) do
    Logger.warning(
      "#{table} delete arrived without token_hash; " <>
        "REPLICA IDENTITY USING INDEX #{table}_token_hash_index is required. " <>
        "Dropping cached rows to stay correct."
    )
  end

  defp standby_status(lsn) do
    <<?r, lsn + 1::64, lsn + 1::64, lsn + 1::64, current_time()::64, 0>>
  end

  @epoch DateTime.to_unix(~U[2000-01-01 00:00:00Z], :microsecond)
  defp current_time, do: System.os_time(:microsecond) - @epoch
end
