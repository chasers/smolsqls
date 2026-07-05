defmodule SqlitesWeb.Hrana.PipelineControllerTest do
  use SqlitesWeb.ConnCase, async: false

  import Sqlites.Fixtures

  setup do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    %{database: database}
  end

  defp pipeline(conn, token, requests) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> post(~p"/v2/pipeline", %{"requests" => requests})
  end

  test "executes a pipeline of statements", %{conn: conn, database: database} do
    body =
      conn
      |> pipeline(database.auth_token, [
        %{type: "execute", stmt: %{sql: "CREATE TABLE t (v TEXT)", want_rows: false}},
        %{
          type: "execute",
          stmt: %{
            sql: "INSERT INTO t VALUES (?)",
            args: [%{type: "text", value: "over-http"}],
            want_rows: false
          }
        },
        %{type: "execute", stmt: %{sql: "SELECT v FROM t", want_rows: true}},
        %{type: "close"}
      ])
      |> json_response(200)

    assert body["baton"] == nil

    assert [
             %{"type" => "ok"},
             %{"type" => "ok"},
             %{
               "type" => "ok",
               "response" => %{
                 "result" => %{"rows" => [[%{"type" => "text", "value" => "over-http"}]]}
               }
             },
             %{"type" => "ok", "response" => %{"type" => "close"}}
           ] = body["results"]
  end

  test "store_sql is scoped to the pipeline", %{conn: conn, database: database} do
    body =
      conn
      |> pipeline(database.auth_token, [
        %{type: "store_sql", sql_id: 1, sql: "SELECT 42"},
        %{type: "execute", stmt: %{sql_id: 1, want_rows: true}}
      ])
      |> json_response(200)

    assert [_, %{"response" => %{"result" => %{"rows" => [[%{"value" => "42"}]]}}}] =
             body["results"]

    body =
      conn
      |> pipeline(database.auth_token, [
        %{type: "execute", stmt: %{sql_id: 1, want_rows: true}}
      ])
      |> json_response(200)

    assert [%{"type" => "error", "error" => %{"message" => message}}] = body["results"]
    assert message =~ "unknown sql_id"
  end

  test "rejects bad tokens, batons, and BEGIN", %{conn: conn, database: database} do
    conn
    |> pipeline("wrong-token", [])
    |> json_response(401)

    body =
      conn
      |> put_req_header("authorization", "Bearer " <> database.auth_token)
      |> post(~p"/v2/pipeline", %{"baton" => "b", "requests" => []})
      |> json_response(400)

    assert body["error"]["message"] =~ "baton"

    body =
      conn
      |> pipeline(database.auth_token, [
        %{type: "execute", stmt: %{sql: "BEGIN", want_rows: false}}
      ])
      |> json_response(200)

    assert [%{"type" => "error", "error" => %{"message" => message}}] = body["results"]
    assert message =~ "transactions"
  end

  test "errors in one request do not abort the pipeline", %{conn: conn, database: database} do
    body =
      conn
      |> pipeline(database.auth_token, [
        %{type: "execute", stmt: %{sql: "SELEC nope", want_rows: false}},
        %{type: "execute", stmt: %{sql: "SELECT 1", want_rows: true}}
      ])
      |> json_response(200)

    assert [%{"type" => "error"}, %{"type" => "ok"}] = body["results"]
  end
end
