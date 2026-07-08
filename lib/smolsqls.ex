defmodule Smolsqls do
  @moduledoc """
  Cross-plane orchestration: operations that must touch the control
  plane, the infra layer, and the data plane in order. Web layers call
  these instead of sequencing the planes themselves.
  """

  alias Smolsqls.ControlPlane
  alias Smolsqls.ControlPlane.{Database, Tenant}
  alias Smolsqls.DataPlane
  alias Smolsqls.Infra

  @spec create_database(Tenant.t(), map()) :: {:ok, Database.t()} | {:error, term()}
  def create_database(%Tenant{} = tenant, attrs) do
    with {:ok, database} <- ControlPlane.create_database(tenant, attrs),
         {:ok, database} <- DataPlane.place_database(database),
         :ok <- Infra.provision(database) do
      {:ok, database}
    end
  end

  @doc """
  Branches `source` into a new independent database seeded from a snapshot.

  Copies the source's latest shipped artifact (its idle snapshot, else its
  newest backup) into the child's idle-snapshot key, creates the child row
  with lineage, and places it — restoring the seeded bytes. Zero impact on
  the source's writer. Returns `{:error, :no_snapshot}` when the source has
  never shipped a snapshot and has no backup to branch from.

  On a failure after the child row is created, the partial branch is cleaned
  up best-effort (robust, idempotent cleanup is a separate concern).
  """
  @spec branch_database(Database.t(), map()) :: {:ok, Database.t()} | {:error, term()}
  def branch_database(%Database{} = source, attrs) do
    with {:ok, source_key} <- source_snapshot_key(source),
         {:ok, child} <- ControlPlane.branch_database(source, attrs),
         {:ok, placed} <- seed_and_place(child, source_key) do
      {:ok, %{placed | auth_token: child.auth_token}}
    end
  end

  defp source_snapshot_key(%Database{} = source) do
    if (source.snapshot_generation || 0) > 0 do
      {:ok, Smolsqls.DataPlane.IdleSnapshots.object_key(source)}
    else
      case Smolsqls.Backups.list(source) do
        [latest | _] -> {:ok, latest.object_key}
        [] -> {:error, :no_snapshot}
      end
    end
  end

  defp seed_and_place(%Database{} = child, source_key) do
    with :ok <- DataPlane.seed_branch_from_object(child, source_key),
         {:ok, placed} <- DataPlane.place_branch(child) do
      {:ok, placed}
    else
      error ->
        _ = DataPlane.remove_database(child)
        error
    end
  end

  @spec remove_database(Database.t()) :: {:ok, Database.t()} | {:error, term()}
  def remove_database(%Database{} = database) do
    with {:ok, database} <- ControlPlane.mark_deleting(database),
         :ok <- Infra.deprovision(database),
         :ok <- Smolsqls.Backups.delete_all(database) do
      DataPlane.remove_database(database)
    end
  end

  @spec delete_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, term()}
  def delete_tenant(%Tenant{} = tenant) do
    tenant
    |> ControlPlane.list_databases()
    |> Enum.reduce_while(:ok, fn database, :ok ->
      case remove_database(database) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {database.id, reason}}}
      end
    end)
    |> case do
      :ok -> ControlPlane.delete_tenant(tenant)
      {:error, reason} -> {:error, reason}
    end
  end
end
