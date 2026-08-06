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
    assert response =~ "Change streaming"
    assert response =~ "Point-in-time recovery"
    assert response =~ "30 days (litestream)"
  end

  test "mounts as a public LiveView carrying the region indicator", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(id="region-latency")
  end

  test "shows no dashboard links when signed out", %{conn: conn} do
    response = conn |> get(~p"/") |> html_response(200)

    refute response =~ ">Dashboard</a>"
    refute response =~ "You're signed in"
  end

  test "shows the dashboard nav link and signed-in card when signed in", %{conn: conn} do
    response =
      conn
      |> Plug.Test.init_test_session(%{api_key: "sk_test_key"})
      |> get(~p"/")
      |> html_response(200)

    assert response =~ ~s(href="/dashboard")
    assert response =~ ">Dashboard</a>"
    assert response =~ "You're signed in"
    assert response =~ "your dashboard"
  end

  test "serves a CSP whose script nonce matches the inline bootstrap script", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, csp)
    assert csp =~ "frame-ancestors 'self'"

    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)
  end
end
