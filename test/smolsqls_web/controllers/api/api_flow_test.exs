defmodule SmolsqlsWeb.Api.ApiFlowTest do
  use SmolsqlsWeb.ConnCase, async: false

  import Smolsqls.Fixtures

  alias Smolsqls.DataPlane

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp cleanup_database(body) do
    %{"data" => %{"id" => id}} = body

    on_exit(fn ->
      case Smolsqls.ControlPlane.get_database(id) do
        nil -> :ok
        database -> DataPlane.remove_database(database)
      end
    end)

    body
  end

  describe "GET /v1" do
    test "returns a machine-readable endpoint index", %{conn: conn} do
      body = conn |> get(~p"/v1") |> json_response(200)
      assert body["service"] == "smolsqls"
      assert is_list(body["endpoints"])
      assert body["response_format"] =~ "data"
      assert body["error_format"] =~ "validation_failed"
    end
  end

  describe "POST /v1/tenants" do
    test "signs up a tenant and returns the api key once", %{conn: conn} do
      body =
        conn
        |> post(~p"/v1/tenants", %{"name" => "Agent Org", "slug" => unique_slug()})
        |> json_response(201)

      assert "sk_" <> _ = body["data"]["api_key"]
    end

    test "returns validation errors", %{conn: conn} do
      body =
        conn
        |> post(~p"/v1/tenants", %{"name" => "Agent Org", "slug" => "BAD SLUG"})
        |> json_response(422)

      assert body["error"]["code"] == "validation_failed"
    end

    test "rate-limits signups from one ip with 429", %{conn: conn} do
      for _ <- 1..5 do
        conn
        |> post(~p"/v1/tenants", %{"name" => "Agent Org", "slug" => unique_slug()})
        |> json_response(201)
      end

      body =
        conn
        |> post(~p"/v1/tenants", %{"name" => "Agent Org", "slug" => unique_slug()})
        |> json_response(429)

      assert body["error"]["code"] == "signup_rate_limited"
    end
  end

  describe "tenant self-service" do
    test "get, update, delete with the api key", %{conn: conn} do
      tenant = tenant_fixture()

      body = conn |> authed(tenant.api_key) |> get(~p"/v1/tenant") |> json_response(200)
      assert body["data"]["id"] == tenant.id
      refute Map.has_key?(body["data"], "api_key")

      body =
        conn
        |> authed(tenant.api_key)
        |> patch(~p"/v1/tenant", %{"name" => "Renamed"})
        |> json_response(200)

      assert body["data"]["name"] == "Renamed"

      conn |> authed(tenant.api_key) |> delete(~p"/v1/tenant") |> response(204)
      assert conn |> authed(tenant.api_key) |> get(~p"/v1/tenant") |> json_response(401)
    end

    test "rejects a missing api key", %{conn: conn} do
      assert conn |> get(~p"/v1/tenant") |> json_response(401)
    end
  end

  describe "database lifecycle" do
    test "create returns connection info; query works with the db token", %{conn: conn} do
      tenant = tenant_fixture()

      body =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/databases", %{"name" => "task-db"})
        |> json_response(201)
        |> cleanup_database()

      %{"data" => data} = body
      assert data["status"] == "active"
      assert data["connections"]["libsql"] =~ "libsql://"
      db_id = data["id"]
      db_token = data["auth_token"]

      assert conn
             |> authed(db_token)
             |> post(~p"/v1/databases/#{db_id}/query", %{"sql" => "CREATE TABLE t (v TEXT)"})
             |> json_response(200)

      result =
        conn
        |> authed(db_token)
        |> post(~p"/v1/databases/#{db_id}/query", %{
          "sql" => "INSERT INTO t VALUES (?)",
          "args" => ["hello"]
        })
        |> json_response(200)

      assert result["data"]["num_changes"] == 1

      result =
        conn
        |> authed(db_token)
        |> post(~p"/v1/databases/#{db_id}/query", %{"sql" => "SELECT v FROM t"})
        |> json_response(200)

      assert result["data"]["rows"] == [["hello"]]

      shown =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases/#{db_id}")
        |> json_response(200)

      assert shown["data"]["litestream_enabled"] == false
      refute Map.has_key?(shown["data"], "connections")
      refute Map.has_key?(shown["data"], "auth_token")
    end

    test "query rejects the wrong token and bad SQL", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      assert conn
             |> authed("wrong")
             |> post(~p"/v1/databases/#{database.id}/query", %{"sql" => "SELECT 1"})
             |> json_response(401)

      body =
        conn
        |> authed(database.auth_token)
        |> post(~p"/v1/databases/#{database.id}/query", %{"sql" => "SELEC nope"})
        |> json_response(400)

      assert body["error"]["code"] == "query_error"
    end

    test "list and delete", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      body = conn |> authed(tenant.api_key) |> get(~p"/v1/databases") |> json_response(200)
      assert [%{"id" => id}] = body["data"]
      assert id == database.id

      conn |> authed(tenant.api_key) |> delete(~p"/v1/databases/#{database.id}") |> response(204)

      body = conn |> authed(tenant.api_key) |> get(~p"/v1/databases") |> json_response(200)
      assert body["data"] == []
    end

    test "toggle continuous replication via PATCH", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      body =
        conn
        |> authed(tenant.api_key)
        |> patch(~p"/v1/databases/#{database.id}", %{"litestream_enabled" => true})
        |> json_response(200)

      assert body["data"]["litestream_enabled"] == true

      body =
        conn
        |> authed(tenant.api_key)
        |> patch(~p"/v1/databases/#{database.id}", %{"litestream_enabled" => false})
        |> json_response(200)

      assert body["data"]["litestream_enabled"] == false
    end

    test "cannot touch another tenant's database", %{conn: conn} do
      tenant = tenant_fixture()
      other_tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      assert conn
             |> authed(other_tenant.api_key)
             |> get(~p"/v1/databases/#{database.id}")
             |> json_response(404)
    end
  end

  describe "backups over the API" do
    test "trigger, list, restore", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)
      {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
      {:ok, _} = DataPlane.query(database.id, "INSERT INTO t VALUES ('keep')")
      on_exit(fn -> Smolsqls.Backups.delete_all(database) end)

      body =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/databases/#{database.id}/backups")
        |> json_response(201)

      backup_id = body["data"]["id"]

      body =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases/#{database.id}/backups")
        |> json_response(200)

      assert [%{"id" => ^backup_id}] = body["data"]

      {:ok, _} = DataPlane.query(database.id, "DELETE FROM t")

      conn
      |> authed(tenant.api_key)
      |> post(~p"/v1/databases/#{database.id}/restore", %{"backup_id" => backup_id})
      |> response(202)

      assert {:ok, %{rows: [["keep"]]}} = DataPlane.query(database.id, "SELECT v FROM t")
    end
  end

  describe "branch over the API" do
    test "branches a database from its latest snapshot", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)
      {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
      {:ok, _} = DataPlane.query(database.id, "INSERT INTO t VALUES ('parent')")
      :ok = DataPlane.idle_stop_database(database)

      body =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/databases/#{database.id}/branch", %{"name" => "branch-db"})
        |> json_response(201)
        |> cleanup_database()

      data = body["data"]
      assert data["status"] == "active"
      assert data["source_database_id"] == database.id
      assert data["branch_point_at"]

      result =
        conn
        |> authed(data["auth_token"])
        |> post(~p"/v1/databases/#{data["id"]}/query", %{"sql" => "SELECT v FROM t"})
        |> json_response(200)

      assert result["data"]["rows"] == [["parent"]]
    end

    test "returns 409 when the source has no snapshot to branch from", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      body =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/databases/#{database.id}/branch", %{"name" => "branch-db"})
        |> json_response(409)

      assert body["error"]["code"] == "no_snapshot"
    end
  end

  describe "token management over the API" do
    test "database tokens: create, list, disable, delete", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      body =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/databases/#{database.id}/tokens", %{"name" => "worker"})
        |> json_response(201)

      token_id = body["data"]["id"]
      secret = body["data"]["token"]
      assert body["data"]["enabled"] == true

      assert conn
             |> authed(secret)
             |> post(~p"/v1/databases/#{database.id}/query", %{"sql" => "SELECT 1"})
             |> json_response(200)

      body =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases/#{database.id}/tokens")
        |> json_response(200)

      assert [%{"name" => "default"} = default_entry, %{"name" => "worker"} = worker_entry] =
               body["data"]

      refute Map.has_key?(default_entry, "token")
      refute Map.has_key?(worker_entry, "token")

      revealed =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/databases/#{database.id}/tokens/#{token_id}/reveal")
        |> json_response(200)

      assert revealed["data"]["token"] == secret

      conn
      |> authed(tenant.api_key)
      |> patch(~p"/v1/databases/#{database.id}/tokens/#{token_id}", %{"enabled" => false})
      |> json_response(200)

      assert conn
             |> authed(secret)
             |> post(~p"/v1/databases/#{database.id}/query", %{"sql" => "SELECT 1"})
             |> json_response(401)

      conn
      |> authed(tenant.api_key)
      |> delete(~p"/v1/databases/#{database.id}/tokens/#{token_id}")
      |> response(204)

      body =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases/#{database.id}/tokens")
        |> json_response(200)

      assert [%{"name" => "default"}] = body["data"]
    end

    test "database tokens can carry an expiration", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      body =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/databases/#{database.id}/tokens", %{
          "expires_at" => DateTime.to_iso8601(expires_at)
        })
        |> json_response(201)

      assert body["data"]["expires_at"]

      body =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/databases/#{database.id}/tokens", %{
          "expires_at" => "2020-01-01T00:00:00Z"
        })
        |> json_response(422)

      assert body["error"]["code"] == "validation_failed"
    end

    test "tenant api keys: create, use, and last-key protection", %{conn: conn} do
      tenant = tenant_fixture()

      body =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/tenant/keys", %{"name" => "ci"})
        |> json_response(201)

      new_key = body["data"]["token"]
      assert conn |> authed(new_key) |> get(~p"/v1/tenant") |> json_response(200)

      body = conn |> authed(tenant.api_key) |> get(~p"/v1/tenant/keys") |> json_response(200)

      assert [%{"name" => "default", "id" => default_id} = default_entry, %{"name" => "ci"}] =
               body["data"]

      refute Map.has_key?(default_entry, "token")

      revealed =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/tenant/keys/#{default_id}/reveal")
        |> json_response(200)

      assert revealed["data"]["token"] == tenant.api_key

      conn
      |> authed(new_key)
      |> delete(~p"/v1/tenant/keys/#{default_id}")
      |> response(204)

      assert conn |> authed(tenant.api_key) |> get(~p"/v1/tenant") |> json_response(401)

      body = conn |> authed(new_key) |> get(~p"/v1/tenant/keys") |> json_response(200)
      assert [%{"id" => last_id}] = body["data"]

      body =
        conn
        |> authed(new_key)
        |> delete(~p"/v1/tenant/keys/#{last_id}")
        |> json_response(422)

      assert body["error"]["code"] == "last_api_key"
    end
  end

  describe "pagination" do
    test "databases paginate with a cursor", %{conn: conn} do
      tenant = tenant_fixture()
      for i <- 1..5, do: database_fixture(tenant, %{"name" => "page-db-#{i}"})

      page1 =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases?limit=2")
        |> json_response(200)

      assert length(page1["data"]) == 2
      assert page1["next"] == List.last(page1["data"])["id"]

      page2 =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases?limit=2&after=#{page1["next"]}")
        |> json_response(200)

      page3 =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases?limit=2&after=#{page2["next"]}")
        |> json_response(200)

      assert length(page3["data"]) == 1
      assert page3["next"] == nil

      ids =
        Enum.flat_map([page1, page2, page3], fn page -> Enum.map(page["data"], & &1["id"]) end)

      assert length(Enum.uniq(ids)) == 5
    end

    test "rejects bad cursors and limits", %{conn: conn} do
      tenant = tenant_fixture()

      body =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases?after=not-a-row")
        |> json_response(400)

      assert body["error"]["code"] == "invalid_cursor"

      body =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases?limit=zero")
        |> json_response(400)

      assert body["error"]["code"] == "invalid_limit"
    end

    test "backups paginate newest-first with a cursor", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)
      {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
      on_exit(fn -> Smolsqls.Backups.delete_all(database) end)

      for _ <- 1..3 do
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/databases/#{database.id}/backups")
        |> json_response(201)
      end

      page1 =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases/#{database.id}/backups?limit=2")
        |> json_response(200)

      assert length(page1["data"]) == 2

      page2 =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases/#{database.id}/backups?limit=2&after=#{page1["next"]}")
        |> json_response(200)

      assert length(page2["data"]) == 1
      assert page2["next"] == nil

      ids = Enum.map(page1["data"] ++ page2["data"], & &1["id"])
      assert length(Enum.uniq(ids)) == 3
    end
  end

  describe "quotas and limits over the API" do
    test "database creation stops at the tenant quota with a clean error", %{conn: conn} do
      tenant = tenant_fixture()

      {:ok, tenant} =
        tenant
        |> Ecto.Changeset.change(limits: %{"max_databases" => 1})
        |> Smolsqls.Repo.update()

      conn
      |> authed(tenant.api_key)
      |> post(~p"/v1/databases", %{"name" => "first"})
      |> json_response(201)
      |> cleanup_database()

      body =
        conn
        |> authed(tenant.api_key)
        |> post(~p"/v1/databases", %{"name" => "second"})
        |> json_response(403)

      assert body["error"]["code"] == "database_limit_reached"
    end

    test "database show exposes resolved limits read-only", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant, %{}, limits: %{"rate_limit_rps" => 7})

      body =
        conn
        |> authed(tenant.api_key)
        |> get(~p"/v1/databases/#{database.id}")
        |> json_response(200)

      assert body["data"]["limits"]["rate_limit_rps"] == 7
      assert body["data"]["limits"]["query_timeout_ms"] == 30_000
    end

    test "per-database rate limit returns 429", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant, %{}, limits: %{"rate_limit_rps" => 2})

      responses =
        for _ <- 1..5 do
          conn
          |> authed(database.auth_token)
          |> post(~p"/v1/databases/#{database.id}/query", %{"sql" => "SELECT 1"})
        end

      rejected = Enum.find(responses, &(&1.status == 429))

      assert rejected,
             "expected at least one 429 among #{inspect(Enum.map(responses, & &1.status))}"

      assert json_response(rejected, 429)["error"]["code"] == "rate_limited"
    end

    test "BEGIN is rejected cleanly", %{conn: conn} do
      tenant = tenant_fixture()
      database = placed_database_fixture(tenant)

      body =
        conn
        |> authed(database.auth_token)
        |> post(~p"/v1/databases/#{database.id}/query", %{"sql" => "BEGIN"})
        |> json_response(400)

      assert body["error"]["code"] == "transactions_not_supported"
    end
  end
end
