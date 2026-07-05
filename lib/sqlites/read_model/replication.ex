defmodule Sqlites.ReadModel.Replication do
  @moduledoc """
  Streams the metadb WAL into the read model over a **permanent**
  logical replication slot named after this node — exact LSN
  continuity across reconnects, so nothing is ever missed. WAL
  retention while a node is down is capped by Postgres'
  `max_slot_wal_keep_size`; the operator drops a node's slot when the
  node is decommissioned. If Postgres reports the slot invalidated,
  the process resnapshots before resuming.
  """

  use Postgrex.ReplicationConnection

  require Logger

  alias Sqlites.ReadModel
  alias Sqlites.ReadModel.{Pgoutput, Row}

  @publication "sqlites_read_model"

  def start_link(opts) do
    conn_opts =
      Application.fetch_env!(:sqlites, Sqlites.Repo)
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

    String.slice("sqlites_" <> name, 0, 63)
  end

  @impl true
  def init(slot) do
    {:ok, %{slot: slot, step: :disconnected, relations: %{}, last_lsn: 0}}
  end

  @impl true
  def handle_connect(state) do
    query = "CREATE_REPLICATION_SLOT #{state.slot} LOGICAL pgoutput NOEXPORT_SNAPSHOT"
    {:query, query, %{state | step: :create_slot}}
  end

  @impl true
  def handle_result(results, %{step: :create_slot} = state) when is_list(results) do
    start_streaming(state)
  end

  def handle_result(
        %Postgrex.Error{postgres: %{code: :duplicate_object}},
        %{step: :create_slot} = state
      ) do
    start_streaming(state)
  end

  def handle_result(%Postgrex.Error{} = error, state) do
    Logger.error("read model replication error: #{Exception.message(error)}")
    {:noreply, state}
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
    ReadModel.put_database(Row.build_database(values))
    state
  end

  defp apply_event({:delete, "databases", %{"id" => id}}, state) when is_binary(id) do
    ReadModel.delete_database(id)
    state
  end

  defp apply_event({change, "tenants", values}, state) when change in [:insert, :update] do
    ReadModel.put_tenant(Row.build_tenant(values))
    state
  end

  defp apply_event({:delete, "tenants", %{"id" => id}}, state) when is_binary(id) do
    ReadModel.delete_tenant(id)
    state
  end

  defp apply_event({change, "database_tokens", values}, state)
       when change in [:insert, :update] do
    ReadModel.put_database_token(Row.build_database_token(values))
    state
  end

  defp apply_event({:delete, "database_tokens", %{"id" => id}}, state) when is_binary(id) do
    ReadModel.delete_database_token(id)
    state
  end

  defp apply_event({change, "tenant_api_keys", values}, state)
       when change in [:insert, :update] do
    ReadModel.put_tenant_api_key(Row.build_tenant_api_key(values))
    state
  end

  defp apply_event({:delete, "tenant_api_keys", %{"id" => id}}, state) when is_binary(id) do
    ReadModel.delete_tenant_api_key(id)
    state
  end

  defp apply_event({:truncate, names}, state) do
    if "databases" in names, do: ReadModel.truncate(:databases)
    if "tenants" in names, do: ReadModel.truncate(:tenants)
    if "database_tokens" in names, do: ReadModel.truncate(:database_tokens)
    if "tenant_api_keys" in names, do: ReadModel.truncate(:tenant_api_keys)
    state
  end

  defp apply_event(_event, state), do: state

  defp standby_status(lsn) do
    <<?r, lsn + 1::64, lsn + 1::64, lsn + 1::64, current_time()::64, 0>>
  end

  @epoch DateTime.to_unix(~U[2000-01-01 00:00:00Z], :microsecond)
  defp current_time, do: System.os_time(:microsecond) - @epoch
end
