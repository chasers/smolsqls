defmodule SqlitesWeb.Hrana.SocketTest do
  use Sqlites.DataCase

  import Sqlites.Fixtures

  alias SqlitesWeb.Hrana.Socket

  defp send_message(message, state) do
    {:push, {:text, payload}, state} =
      Socket.handle_in({Jason.encode!(message), opcode: :text}, state)

    {Jason.decode!(payload), state}
  end

  defp connected_state(database) do
    {:ok, state} = Socket.init([])

    {%{"type" => "hello_ok"}, state} =
      send_message(%{type: "hello", jwt: database.auth_token}, state)

    {%{"type" => "response_ok"}, state} =
      send_message(
        %{type: "request", request_id: 0, request: %{type: "open_stream", stream_id: 1}},
        state
      )

    state
  end

  defp execute(sql, args, state) do
    send_message(
      %{
        type: "request",
        request_id: 1,
        request: %{
          type: "execute",
          stream_id: 1,
          stmt: %{sql: sql, args: args, want_rows: true}
        }
      },
      state
    )
  end

  setup do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)
    %{database: database}
  end

  test "rejects a bad auth token" do
    {:ok, state} = Socket.init([])
    {response, _state} = send_message(%{type: "hello", jwt: "wrong"}, state)
    assert %{"type" => "hello_error"} = response
  end

  test "rejects requests before hello" do
    {:ok, state} = Socket.init([])

    {response, _state} =
      send_message(
        %{type: "request", request_id: 7, request: %{type: "open_stream", stream_id: 1}},
        state
      )

    assert %{"type" => "response_error", "request_id" => 7} = response
  end

  test "executes statements with typed args and rows", %{database: database} do
    state = connected_state(database)

    {response, state} = execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", [], state)
    assert %{"type" => "response_ok"} = response

    {response, state} =
      execute("INSERT INTO t (v) VALUES (?)", [%{type: "text", value: "hi"}], state)

    assert %{
             "response" => %{"result" => %{"affected_row_count" => 1, "last_insert_rowid" => "1"}}
           } =
             response

    {response, _state} = execute("SELECT id, v FROM t", [], state)

    assert %{
             "response" => %{
               "result" => %{
                 "cols" => [%{"name" => "id"}, %{"name" => "v"}],
                 "rows" => [
                   [%{"type" => "integer", "value" => "1"}, %{"type" => "text", "value" => "hi"}]
                 ]
               }
             }
           } = response
  end

  test "stored SQL via store_sql/sql_id", %{database: database} do
    state = connected_state(database)

    {response, state} =
      send_message(
        %{
          type: "request",
          request_id: 2,
          request: %{type: "store_sql", sql_id: 0, sql: "SELECT 42"}
        },
        state
      )

    assert %{"type" => "response_ok"} = response

    {response, _state} =
      send_message(
        %{
          type: "request",
          request_id: 3,
          request: %{type: "execute", stream_id: 1, stmt: %{sql_id: 0, want_rows: true}}
        },
        state
      )

    assert %{"response" => %{"result" => %{"rows" => [[%{"value" => "42"}]]}}} = response
  end

  test "returns response_error for bad SQL", %{database: database} do
    state = connected_state(database)
    {response, _state} = execute("SELEC nope", [], state)
    assert %{"type" => "response_error", "error" => %{"message" => message}} = response
    assert message =~ "syntax error"
  end

  test "rejects BEGIN cleanly instead of leaking transaction state", %{database: database} do
    state = connected_state(database)

    {response, state} = execute("BEGIN", [], state)
    assert %{"type" => "response_error", "error" => %{"message" => message}} = response
    assert message =~ "transactions"

    {response, _state} = execute("SELECT 1", [], state)
    assert %{"type" => "response_ok"} = response
  end

  test "binds named args", %{database: database} do
    state = connected_state(database)

    {_response, state} = execute("CREATE TABLE t (a TEXT, b INTEGER)", [], state)

    {response, state} =
      send_message(
        %{
          type: "request",
          request_id: 4,
          request: %{
            type: "execute",
            stream_id: 1,
            stmt: %{
              sql: "INSERT INTO t VALUES (:a, @b)",
              named_args: [
                %{name: "a", value: %{type: "text", value: "named"}},
                %{name: "@b", value: %{type: "integer", value: "7"}}
              ],
              want_rows: false
            }
          }
        },
        state
      )

    assert %{"response" => %{"result" => %{"affected_row_count" => 1}}} = response

    {response, _state} = execute("SELECT a, b FROM t", [], state)

    assert %{
             "response" => %{
               "result" => %{
                 "rows" => [
                   [
                     %{"type" => "text", "value" => "named"},
                     %{"type" => "integer", "value" => "7"}
                   ]
                 ]
               }
             }
           } = response
  end

  test "describe returns cols and param count without executing", %{database: database} do
    state = connected_state(database)
    {_response, state} = execute("CREATE TABLE t (id INTEGER, v TEXT)", [], state)

    {response, _state} =
      send_message(
        %{
          type: "request",
          request_id: 5,
          request: %{type: "describe", stream_id: 1, sql: "SELECT id, v FROM t WHERE id = ?"}
        },
        state
      )

    assert %{
             "type" => "response_ok",
             "response" => %{
               "type" => "describe",
               "result" => %{
                 "cols" => [%{"name" => "id"}, %{"name" => "v"}],
                 "params" => [%{"name" => nil}],
                 "is_readonly" => true
               }
             }
           } = response
  end

  test "sequence executes a multi-statement script", %{database: database} do
    state = connected_state(database)

    {response, state} =
      send_message(
        %{
          type: "request",
          request_id: 6,
          request: %{
            type: "sequence",
            stream_id: 1,
            sql: "CREATE TABLE seq_t (v TEXT); INSERT INTO seq_t VALUES ('a'), ('b');"
          }
        },
        state
      )

    assert %{"type" => "response_ok", "response" => %{"type" => "sequence"}} = response

    {response, _state} = execute("SELECT count(*) FROM seq_t", [], state)
    assert %{"response" => %{"result" => %{"rows" => [[%{"value" => "2"}]]}}} = response
  end

  test "batch reports per-step errors", %{database: database} do
    state = connected_state(database)

    {response, _state} =
      send_message(
        %{
          type: "request",
          request_id: 8,
          request: %{
            type: "batch",
            stream_id: 1,
            batch: %{
              steps: [
                %{stmt: %{sql: "CREATE TABLE b (v TEXT)", want_rows: false}},
                %{stmt: %{sql: "BEGIN", want_rows: false}},
                %{stmt: %{sql: "INSERT INTO b VALUES ('x')", want_rows: false}}
              ]
            }
          }
        },
        state
      )

    assert %{
             "type" => "response_ok",
             "response" => %{
               "result" => %{
                 "step_results" => [%{}, nil, %{}],
                 "step_errors" => [nil, %{"message" => message}, nil]
               }
             }
           } = response

    assert message =~ "transactions"
  end
end
