defmodule Sqlites.ControlPlaneTest do
  use Sqlites.DataCase

  import Sqlites.Fixtures

  alias Sqlites.ControlPlane

  describe "tenants" do
    test "create_tenant/1 generates an api key" do
      assert {:ok, tenant} =
               ControlPlane.create_tenant(%{"name" => "Acme", "slug" => unique_slug()})

      assert "sk_" <> _ = tenant.api_key
    end

    test "create_tenant/1 rejects an invalid slug" do
      assert {:error, changeset} =
               ControlPlane.create_tenant(%{"name" => "Acme", "slug" => "Not A Slug"})

      assert %{slug: _} = errors_on(changeset)
    end

    test "create_tenant/1 rejects a duplicate slug" do
      slug = unique_slug()
      assert {:ok, _} = ControlPlane.create_tenant(%{"name" => "Acme", "slug" => slug})
      assert {:error, changeset} = ControlPlane.create_tenant(%{"name" => "Acme", "slug" => slug})
      assert %{slug: _} = errors_on(changeset)
    end

    test "authenticate_tenant/1 finds a tenant by api key" do
      tenant = tenant_fixture()
      assert {:ok, found} = ControlPlane.authenticate_tenant(tenant.api_key)
      assert found.id == tenant.id
      assert {:error, :unauthorized} = ControlPlane.authenticate_tenant("sk_bogus")
    end

    test "update_tenant/2 changes the name" do
      tenant = tenant_fixture()
      assert {:ok, updated} = ControlPlane.update_tenant(tenant, %{"name" => "Renamed"})
      assert updated.name == "Renamed"
    end

    test "delete_tenant/1 removes the tenant" do
      tenant = tenant_fixture()
      assert {:ok, _} = ControlPlane.delete_tenant(tenant)
      assert ControlPlane.get_tenant(tenant.id) == nil
    end
  end

  describe "databases" do
    test "create_database/2 generates an auth token" do
      tenant = tenant_fixture()
      assert {:ok, database} = ControlPlane.create_database(tenant, %{"name" => "tasks"})
      assert database.status == :pending
      assert is_binary(database.auth_token)
    end

    test "create_database/2 rejects duplicate names per tenant" do
      tenant = tenant_fixture()
      assert {:ok, _} = ControlPlane.create_database(tenant, %{"name" => "tasks"})
      assert {:error, changeset} = ControlPlane.create_database(tenant, %{"name" => "tasks"})
      assert %{tenant_id: _} = errors_on(changeset)
    end

    test "get_database/2 scopes lookup to the tenant" do
      tenant = tenant_fixture()
      other_tenant = tenant_fixture()
      database = database_fixture(tenant)

      assert %{id: _} = ControlPlane.get_database(tenant, database.id)
      assert ControlPlane.get_database(other_tenant, database.id) == nil
      assert ControlPlane.get_database(tenant, "not-a-uuid") == nil
    end

    test "authenticate_database/2 checks the token" do
      tenant = tenant_fixture()
      database = database_fixture(tenant)

      assert {:ok, _} = ControlPlane.authenticate_database(database.id, database.auth_token)
      assert {:error, :unauthorized} = ControlPlane.authenticate_database(database.id, "wrong")
      assert {:error, :unauthorized} = ControlPlane.authenticate_database("junk-id", "wrong")
    end

    test "list_databases/1 returns only the tenant's databases" do
      tenant = tenant_fixture()
      other_tenant = tenant_fixture()
      database = database_fixture(tenant)
      database_fixture(other_tenant)

      assert [%{id: id}] = ControlPlane.list_databases(tenant)
      assert id == database.id
    end

    test "mark_placed/3 records node and file path" do
      tenant = tenant_fixture()
      database = database_fixture(tenant)

      assert {:ok, placed} = ControlPlane.mark_placed(database, Node.self(), "/tmp/x.db")
      assert placed.status == :active
      assert placed.node == to_string(Node.self())
      assert placed.file_path == "/tmp/x.db"
    end
  end

  describe "database tokens" do
    test "creation includes a default token that authenticates" do
      tenant = tenant_fixture()
      database = database_fixture(tenant)

      assert is_binary(database.auth_token)
      assert [%{name: "default"} = token] = ControlPlane.list_database_tokens(database)
      assert token.token == nil
      assert token.token_hash == Sqlites.Secrets.hash(database.auth_token)

      assert {:ok, revealed} = ControlPlane.reveal(token)
      assert revealed.token == database.auth_token

      assert {:ok, _} = ControlPlane.authenticate_database(database.id, database.auth_token)
      assert {:ok, _} = ControlPlane.authenticate_database_by_token(database.auth_token)

      assert {:error, :unauthorized} =
               ControlPlane.authenticate_database(database.id, "not-a-token")
    end

    test "several tokens authenticate independently; disable and delete revoke" do
      tenant = tenant_fixture()
      database = database_fixture(tenant)

      {:ok, second} = ControlPlane.create_database_token(database, %{"name" => "worker"})

      assert {:ok, _} = ControlPlane.authenticate_database(database.id, second.token)
      assert {:ok, _} = ControlPlane.authenticate_database(database.id, database.auth_token)

      {:ok, second} = ControlPlane.update_database_token(second, %{"enabled" => false})

      assert {:error, :unauthorized} =
               ControlPlane.authenticate_database(database.id, second.token)

      {:ok, second} = ControlPlane.update_database_token(second, %{"enabled" => true})
      assert {:ok, _} = ControlPlane.authenticate_database(database.id, second.token)

      {:ok, _} = ControlPlane.delete_database_token(second)

      assert {:error, :unauthorized} =
               ControlPlane.authenticate_database(database.id, second.token)

      assert {:ok, _} = ControlPlane.authenticate_database(database.id, database.auth_token)
    end

    test "an expired token stops authenticating" do
      tenant = tenant_fixture()
      database = database_fixture(tenant)

      {:ok, token} =
        ControlPlane.create_database_token(database, %{
          "expires_at" => DateTime.add(DateTime.utc_now(), 60, :second)
        })

      assert {:ok, _} = ControlPlane.authenticate_database(database.id, token.token)

      {:ok, _} =
        token
        |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
        |> Repo.update()

      assert {:error, :unauthorized} =
               ControlPlane.authenticate_database(database.id, token.token)
    end

    test "rejects an expiration in the past at create time" do
      tenant = tenant_fixture()
      database = database_fixture(tenant)

      assert {:error, changeset} =
               ControlPlane.create_database_token(database, %{
                 "expires_at" => DateTime.add(DateTime.utc_now(), -60, :second)
               })

      assert %{expires_at: _} = errors_on(changeset)
    end

    test "a token never authenticates another database" do
      tenant = tenant_fixture()
      database = database_fixture(tenant)
      other = database_fixture(tenant)

      assert {:error, :unauthorized} =
               ControlPlane.authenticate_database(other.id, database.auth_token)
    end
  end

  describe "tenant api keys" do
    test "signup includes a default key; more keys can be created and revoked" do
      tenant = tenant_fixture()

      assert {:ok, _} = ControlPlane.authenticate_tenant(tenant.api_key)

      {:ok, second} = ControlPlane.create_tenant_api_key(tenant, %{"name" => "ci"})
      assert "sk_" <> _ = second.token
      assert {:ok, _} = ControlPlane.authenticate_tenant(second.token)

      {:ok, _} = ControlPlane.update_tenant_api_key(second, %{"enabled" => false})
      assert {:error, :unauthorized} = ControlPlane.authenticate_tenant(second.token)

      [first_key, second_key] = ControlPlane.list_tenant_api_keys(tenant)
      assert first_key.name == "default"
      refute second_key.enabled

      {:ok, _} = ControlPlane.delete_tenant_api_key(second_key)
      assert ControlPlane.list_tenant_api_keys(tenant) |> length() == 1
    end

    test "the last usable key cannot be disabled or deleted" do
      tenant = tenant_fixture()
      [only_key] = ControlPlane.list_tenant_api_keys(tenant)

      assert {:error, :last_api_key} =
               ControlPlane.update_tenant_api_key(only_key, %{"enabled" => false})

      assert {:error, :last_api_key} = ControlPlane.delete_tenant_api_key(only_key)

      {:ok, _} = ControlPlane.create_tenant_api_key(tenant, %{"name" => "backup"})
      assert {:ok, _} = ControlPlane.delete_tenant_api_key(only_key)
    end
  end
end
