defmodule SmolsqlsWeb.MetricsControllerTest do
  use SmolsqlsWeb.ConnCase, async: false

  import Smolsqls.Fixtures

  test "GET /metrics exposes data-plane metrics in Prometheus format", %{conn: conn} do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    {:ok, _} = Smolsqls.DataPlane.query(database.id, "SELECT 1")

    body = conn |> get(~p"/metrics") |> response(200)

    assert body =~ "smolsqls_query_count"
    assert body =~ ~s(result="ok")
    assert body =~ ~s(cold="false")
  end
end
