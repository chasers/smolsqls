defmodule Smolsqls.ReadModel.ProjectionTest do
  @moduledoc """
  The cache is populated by two independent paths — a Postgres read on a
  miss (`Source`) and the WAL feed (`Row`) — and both must produce the
  same shape. If one path stops populating a projected field, the field
  silently becomes `nil` depending on how a row got cached, which is the
  hardest class of bug to see in production.
  """

  use Smolsqls.DataCase

  import Smolsqls.Fixtures

  alias Smolsqls.ReadModel.{Projection, Row, Source}

  test "Row and Source populate exactly the projected fields for a database" do
    tenant = tenant_fixture()
    database = placed_database_fixture(tenant)

    assert {:ok, loaded} = Source.fetch(:databases, database.id)

    built =
      Row.build_database(%{
        "id" => database.id,
        "tenant_id" => tenant.id,
        "status" => "active",
        "node" => to_string(Node.self()),
        "region" => nil,
        "cloud" => nil,
        "file_path" => "/tmp/x.db",
        "litestream_enabled" => "f",
        "snapshot_generation" => "0",
        "limits" => "{}"
      })

    assert_projected(loaded, built, :databases)
  end

  test "Row and Source populate exactly the projected fields for a tenant" do
    tenant = tenant_fixture()

    assert {:ok, loaded} = Source.fetch(:tenants, tenant.id)
    built = Row.build_tenant(%{"id" => tenant.id, "limits" => "{}"})

    assert_projected(loaded, built, :tenants)
  end

  test "Row and Source populate exactly the projected fields for a database token" do
    tenant = tenant_fixture()
    database = database_fixture(tenant)
    hash = Smolsqls.Secrets.hash(database.auth_token)

    assert {:ok, loaded} = Source.fetch(:database_tokens, hash)

    built =
      Row.build_database_token(%{
        "id" => loaded.id,
        "database_id" => database.id,
        "token_hash" => hash,
        "enabled" => "t",
        "expires_at" => nil
      })

    assert_projected(loaded, built, :database_tokens)
  end

  defp assert_projected(from_postgres, from_feed, table) do
    projected = MapSet.new(Projection.fields(table))

    assert MapSet.subset?(populated(from_postgres), projected),
           "the Postgres read populated fields outside the projection: " <>
             inspect(MapSet.difference(populated(from_postgres), projected))

    assert MapSet.subset?(populated(from_feed), projected),
           "the WAL feed populated fields outside the projection: " <>
             inspect(MapSet.difference(populated(from_feed), projected))

    assert populated(from_postgres) == populated(from_feed),
           "the two paths disagree on which fields a cached row carries: " <>
             inspect(MapSet.symmetric_difference(populated(from_postgres), populated(from_feed)))
  end

  defp populated(%schema{} = row) do
    schema.__schema__(:fields)
    |> Enum.reject(fn field -> is_nil(Map.fetch!(row, field)) end)
    |> MapSet.new()
  end
end
