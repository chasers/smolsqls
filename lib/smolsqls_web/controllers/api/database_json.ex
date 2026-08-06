defmodule SmolsqlsWeb.Api.DatabaseJSON do
  alias Smolsqls.ControlPlane.Database
  alias SmolsqlsWeb.ConnectionStrings

  def index(%{databases: databases, next: next}) do
    %{data: Enum.map(databases, &data(&1, false, nil)), next: next}
  end

  def show(%{database: database, limits: limits, include_token: include_token}) do
    %{data: data(database, include_token, limits)}
  end

  defp data(%Database{} = database, include_token, limits) do
    base = %{
      id: database.id,
      name: database.name,
      status: database.status,
      region: database.region,
      cloud: database.cloud,
      litestream_enabled: database.litestream_enabled,
      change_stream_enabled: database.change_stream_enabled,
      created_at: database.inserted_at,
      source_database_id: database.source_database_id,
      branch_point_at: database.branch_point_at,
      expires_at: database.expires_at
    }

    cond do
      include_token and is_binary(database.auth_token) ->
        base
        |> Map.put(:auth_token, database.auth_token)
        |> Map.put(:limits, limits)
        |> Map.put(:connections, connections(database))

      include_token ->
        Map.put(base, :limits, limits)

      true ->
        base
    end
  end

  defp connections(%Database{} = database) do
    global = %{
      libsql: ConnectionStrings.libsql_url(ConnectionStrings.global_host(), database.auth_token),
      http: http_connection(ConnectionStrings.global_host(), database)
    }

    case database.region do
      region when is_binary(region) ->
        Map.put(global, :regional, %{
          region: region,
          libsql:
            ConnectionStrings.libsql_url(
              ConnectionStrings.regional_host(region),
              database.auth_token
            ),
          http: http_connection(ConnectionStrings.regional_host(region), database)
        })

      _ ->
        global
    end
  end

  defp http_connection(host, %Database{} = database) do
    %{
      url: ConnectionStrings.http_base(host) <> "/v1/databases/#{database.id}/query",
      method: "POST",
      headers: %{authorization: "Bearer #{database.auth_token}"},
      body: %{sql: "SELECT 1", args: []}
    }
  end
end
