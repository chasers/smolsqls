defmodule SmolsqlsWeb.HomeLiveTest do
  use SmolsqlsWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "Use your account API key"
    assert response =~ "Create a tenant"
    assert response =~ "Platform limits"
    assert response =~ "Databases per account"
    assert response =~ "1 GiB"
    assert response =~ "Backups"
    assert response =~ "daily"
    assert response =~ "Database branching"
    assert response =~ "Point-in-time recovery"
    assert response =~ "30 days (litestream)"
  end

  test "mounts as a public LiveView carrying the region indicator", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(id="region-latency")
  end

  test "serves a CSP whose script nonce matches the inline bootstrap script", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, csp)
    assert csp =~ "frame-ancestors 'self'"

    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)
  end
end
