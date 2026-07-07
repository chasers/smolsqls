defmodule SmolsqlsWeb.PageControllerTest do
  use SmolsqlsWeb.ConnCase

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
  end

  test "serves a CSP whose script nonce matches the inline bootstrap script", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, csp)
    assert csp =~ "frame-ancestors 'self'"

    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)
  end
end
