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
end
