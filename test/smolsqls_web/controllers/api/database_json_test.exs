defmodule SmolsqlsWeb.Api.DatabaseJSONTest do
  use ExUnit.Case, async: true

  alias Smolsqls.ControlPlane.Database
  alias SmolsqlsWeb.Api.DatabaseJSON

  defp database(attrs) do
    struct(
      %Database{
        id: "11111111-1111-1111-1111-111111111111",
        name: "db",
        status: :active,
        inserted_at: ~U[2026-07-10 00:00:00.000000Z]
      },
      attrs
    )
  end

  test "surfaces region and cloud on reads without a token" do
    db = database(region: "gcp-us-central1", cloud: "gcp")
    %{data: data} = DatabaseJSON.show(%{database: db, include_token: false})

    assert data.region == "gcp-us-central1"
    assert data.cloud == "gcp"
    refute Map.has_key?(data, :connections)
  end

  test "emits global and regional connection strings when a token is included" do
    db = database(region: "gcp-us-central1", cloud: "gcp", auth_token: "sk_test")
    %{data: data} = DatabaseJSON.show(%{database: db, include_token: true})

    assert data.connections.libsql =~ "libsql://"
    assert data.connections.libsql =~ "authToken=sk_test"

    regional = data.connections.regional
    assert regional.region == "gcp-us-central1"
    assert regional.libsql =~ "gcp-us-central1"
    assert regional.http.url =~ "gcp-us-central1"
    assert regional.http.url =~ "/v1/databases/#{db.id}/query"
  end

  test "omits the regional block when the database has no region" do
    db = database(region: nil, auth_token: "sk_test")
    %{data: data} = DatabaseJSON.show(%{database: db, include_token: true})

    assert data.connections.libsql =~ "libsql://"
    refute Map.has_key?(data.connections, :regional)
  end
end
