defmodule Sqlites.Fixtures do
  @moduledoc """
  Test data helpers for tenants and databases.
  """

  alias Sqlites.ControlPlane

  def unique_slug, do: "org-#{System.unique_integer([:positive])}"

  def tenant_fixture(attrs \\ %{}) do
    {:ok, tenant} =
      attrs
      |> Enum.into(%{"name" => "Test Org", "slug" => unique_slug()})
      |> ControlPlane.create_tenant()

    tenant
  end

  def database_fixture(tenant, attrs \\ %{}) do
    {:ok, database} =
      ControlPlane.create_database(
        tenant,
        Enum.into(attrs, %{"name" => "db-#{System.unique_integer([:positive])}"})
      )

    database
  end

  def placed_database_fixture(tenant, attrs \\ %{}, opts \\ []) do
    database = database_fixture(tenant, attrs)

    database =
      case Keyword.get(opts, :limits) do
        nil ->
          database

        limits ->
          database
          |> Ecto.Changeset.change(limits: limits)
          |> Sqlites.Repo.update!()
      end

    {:ok, database} = Sqlites.DataPlane.place_database(database)

    ExUnit.Callbacks.on_exit(fn ->
      Sqlites.DataPlane.Supervisor.stop_database(database.id)

      if database.file_path do
        Sqlites.DataPlane.delete_local_files(database.file_path)
      end
    end)

    database
  end
end
