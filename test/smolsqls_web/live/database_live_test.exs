defmodule SmolsqlsWeb.DatabaseLive.IndexTest do
  use SmolsqlsWeb.ConnCase

  import Phoenix.LiveViewTest
  import Smolsqls.Fixtures

  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane

  defp authed_conn(conn, tenant) do
    init_test_session(conn, %{api_key: tenant.api_key})
  end

  defp snapshotted_database(tenant) do
    database = placed_database_fixture(tenant)
    {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
    :ok = DataPlane.idle_stop_database(database)
    database
  end

  defp cleanup_branches(tenant) do
    on_exit(fn ->
      for db <- ControlPlane.list_databases(tenant), db.source_database_id do
        DataPlane.Supervisor.stop_database(db.id)
        if db.file_path, do: DataPlane.delete_local_files(db.file_path)
      end
    end)
  end

  test "redirects to / when unauthenticated", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/dashboard")
  end

  test "create form shows a region dropdown defaulting to the configured default", %{conn: conn} do
    Application.put_env(:smolsqls, :regions, ["gcp-us-central1", "gcp-europe-west1"])
    Application.put_env(:smolsqls, :default_region, "gcp-us-central1")

    on_exit(fn ->
      Application.put_env(:smolsqls, :regions, [])
      Application.put_env(:smolsqls, :default_region, nil)
    end)

    tenant = tenant_fixture()
    {:ok, _view, html} = live(authed_conn(conn, tenant), ~p"/dashboard")

    assert html =~ ~s(name="region")
    assert html =~ "gcp-europe-west1"
    assert html =~ ~r/<option[^>]*value="gcp-us-central1"[^>]*selected/
  end

  test "branches a database from its snapshot and nests it under the parent", %{conn: conn} do
    tenant = tenant_fixture()
    source = snapshotted_database(tenant)
    cleanup_branches(tenant)

    {:ok, view, _html} = live(authed_conn(conn, tenant), ~p"/dashboard")

    view
    |> element(~s(button[phx-click=toggle_branch][phx-value-id="#{source.id}"]))
    |> render_click()

    html =
      view
      |> form("#branch-#{source.id}", %{"name" => "my-branch"})
      |> render_submit()

    assert html =~ "my-branch"
    assert html =~ "⑃ 1"

    branches =
      tenant |> ControlPlane.list_databases() |> Enum.filter(& &1.source_database_id)

    assert [%{name: "my-branch", source_database_id: source_id}] = branches
    assert source_id == source.id
  end

  test "shows a clear message when branching a source with no snapshot", %{conn: conn} do
    tenant = tenant_fixture()
    source = placed_database_fixture(tenant)

    {:ok, view, _html} = live(authed_conn(conn, tenant), ~p"/dashboard")

    view
    |> element(~s(button[phx-click=toggle_branch][phx-value-id="#{source.id}"]))
    |> render_click()

    html =
      view
      |> form("#branch-#{source.id}", %{"name" => "no-snap"})
      |> render_submit()

    assert html =~ "No snapshot yet"
  end
end
