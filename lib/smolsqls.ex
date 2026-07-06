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
