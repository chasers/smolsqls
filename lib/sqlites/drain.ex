defmodule Sqlites.Drain do
  @moduledoc """
  Orderly node evacuation, cheap because volumes are caches: hot
  databases are idle-stopped first (shipping their snapshots), cold
  databases that have never shipped are woken once so their idle-stop
  establishes generation 1, and then every placement row moves to the
  surviving nodes — metadata-only for anything already in the object
  store. Activation on the new owner restores lazily from S3.

  Requests arrive on the `node_drains` metadb table (see
  `Sqlites.Drain.Worker`); a drain can also be run directly:

      bin/sqlites rpc 'Sqlites.Drain.drain("sqlites@node-to-drain...")'
  """

  import Ecto.Query

  require Logger

  alias Sqlites.ControlPlane.Database
  alias Sqlites.DataPlane
  alias Sqlites.Repo

  @spec drain(String.t()) ::
          {:ok, %{reassigned: non_neg_integer(), handed_off: non_neg_integer()}}
          | {:error, term()}
  def drain(node_name) when is_binary(node_name) do
    survivors =
      [Node.self() | Node.list()]
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == node_name))

    if survivors == [] do
      {:error, :no_survivors}
    else
      do_drain(node_name)
    end
  end

  defp do_drain(node_name) do
    databases =
      Database
      |> where([d], d.node == ^node_name)
      |> Repo.all()

    handed_off = Enum.count(databases, &hand_off/1)

    with {:ok, %{reassigned: reassigned}} <- Sqlites.Failover.evacuate(node_name) do
      Logger.info("drain #{node_name}: handed off #{handed_off}, reassigned #{reassigned}")
      {:ok, %{reassigned: reassigned, handed_off: handed_off}}
    end
  end

  defp hand_off(%Database{} = database) do
    cond do
      hot?(database) ->
        DataPlane.idle_stop_database(database) == :ok

      (database.snapshot_generation || 0) == 0 and database.status == :active ->
        establish_first_snapshot(database)

      true ->
        false
    end
  end

  defp hot?(%Database{id: id}) do
    match?({:ok, _node}, DataPlane.owner_node(id))
  end

  defp establish_first_snapshot(%Database{} = database) do
    case DataPlane.activate_database(database) do
      {:ok, _pid} ->
        DataPlane.idle_stop_database(database) == :ok

      {:error, reason} ->
        Logger.warning(
          "drain: could not wake never-shipped database #{database.id}: #{inspect(reason)}"
        )

        false
    end
  end
end
