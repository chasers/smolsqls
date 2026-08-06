defmodule SmolsqlsWeb.DatabaseLive.ChangesTest do
  use SmolsqlsWeb.ConnCase

  import Phoenix.LiveViewTest
  import Smolsqls.Fixtures

  alias Smolsqls.DataPlane
  alias Smolsqls.DataPlane.ChangeStream

  defp authed_conn(conn, tenant) do
    init_test_session(conn, %{api_key: tenant.api_key})
  end

  test "redirects to / when unauthenticated", %{conn: conn} do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/dashboard/databases/#{database.id}/changes")
  end

  test "redirects to /dashboard for another tenant's database", %{conn: conn} do
    owner = tenant_fixture()
    database = placed_database_fixture(owner)
    other = tenant_fixture()

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(authed_conn(conn, other), ~p"/dashboard/databases/#{database.id}/changes")
  end

  test "renders live change events as they arrive", %{conn: conn} do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    {:ok, view, html} =
      live(authed_conn(conn, tenant), ~p"/dashboard/databases/#{database.id}/changes")

    assert html =~ "change stream"
    assert html =~ "Waiting for changes"

    Smolsqls.Wait.until(fn -> ChangeStream.subscriber_count(database.id) == 1 end)

    {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    {:ok, _} = DataPlane.query(database.id, "INSERT INTO t (v) VALUES (?)", ["streamed"])

    Smolsqls.Wait.until(fn -> render(view) =~ "streamed" end)

    html = render(view)
    assert html =~ "insert"
    assert html =~ ~s(&quot;v&quot;:&quot;streamed&quot;)

    {:ok, _} = DataPlane.query(database.id, "DELETE FROM t WHERE id = 1")

    Smolsqls.Wait.until(fn -> render(view) =~ "delete" end)
  end

  test "answers the layout's ping hook", %{conn: conn} do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    {:ok, view, _html} =
      live(authed_conn(conn, tenant), ~p"/dashboard/databases/#{database.id}/changes")

    assert render_hook(view, "ping", %{})
  end

  test "the database list links to the change stream", %{conn: conn} do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    {:ok, _view, html} = live(authed_conn(conn, tenant), ~p"/dashboard")

    assert html =~ ~p"/dashboard/databases/#{database.id}/changes"
  end
end
