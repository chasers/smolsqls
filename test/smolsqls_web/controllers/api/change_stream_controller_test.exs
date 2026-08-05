defmodule SmolsqlsWeb.Api.ChangeStreamControllerTest do
  use SmolsqlsWeb.ConnCase, async: false

  import Smolsqls.Fixtures

  alias Smolsqls.DataPlane
  alias Smolsqls.DataPlane.ChangeStream

  setup do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    %{database: database}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp changes_path(database, params) do
    "/v1/databases/#{database.id}/changes?" <> URI.encode_query(params)
  end

  test "streams change events as SSE frames until max_events", %{
    conn: conn,
    database: database
  } do
    task =
      Task.async(fn ->
        conn
        |> authed(database.auth_token)
        |> get(changes_path(database, max_events: 2, timeout_ms: 5_000))
      end)

    Smolsqls.Wait.until(fn -> ChangeStream.subscriber_count(database.id) == 1 end)

    {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    {:ok, _} = DataPlane.query(database.id, "INSERT INTO t (v) VALUES (?)", ["x"])
    {:ok, _} = DataPlane.query(database.id, "DELETE FROM t WHERE id = 1")

    conn = Task.await(task)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]

    assert conn.resp_body =~ "event: change\ndata: "
    assert conn.resp_body =~ ~s("action":"insert")
    assert conn.resp_body =~ ~s("record":{"id":1,"v":"x"})
    assert conn.resp_body =~ ~s("action":"delete")
  end

  test "closes the stream at the deadline with keepalives only", %{
    conn: conn,
    database: database
  } do
    conn =
      conn
      |> authed(database.auth_token)
      |> get(changes_path(database, timeout_ms: 50))

    assert conn.status == 200
    assert conn.resp_body == ": keepalive\n\n"
  end

  test "unsubscribes when the stream ends", %{conn: conn, database: database} do
    conn
    |> authed(database.auth_token)
    |> get(changes_path(database, timeout_ms: 50))

    assert ChangeStream.subscriber_count(database.id) == 0
  end

  test "rejects a missing bearer token", %{conn: conn, database: database} do
    body = conn |> get(changes_path(database, [])) |> json_response(401)
    assert body["error"]["code"] == "unauthorized"
  end

  test "rejects a wrong token", %{conn: conn, database: database} do
    body =
      conn
      |> authed("not-the-token")
      |> get(changes_path(database, []))
      |> json_response(401)

    assert body["error"]["code"] == "unauthorized"
  end
end
