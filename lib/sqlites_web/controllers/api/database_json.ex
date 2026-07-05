defmodule SqlitesWeb.Api.DatabaseJSON do
  alias Sqlites.ControlPlane.Database

  def index(%{databases: databases, next: next}) do
    %{data: Enum.map(databases, &data(&1, false)), next: next}
  end

  def show(%{database: database, include_token: include_token}) do
    %{data: data(database, include_token)}
  end

  defp data(%Database{} = database, include_token) do
    base = %{
      id: database.id,
      name: database.name,
      status: database.status,
      litestream: database.litestream_enabled,
      created_at: database.inserted_at
    }

    cond do
      include_token and is_binary(database.auth_token) ->
        base
        |> Map.put(:auth_token, database.auth_token)
        |> Map.put(:limits, Sqlites.Limits.resolve(database))
        |> Map.put(:connections, connections(database))

      include_token ->
        Map.put(base, :limits, Sqlites.Limits.resolve(database))

      true ->
        base
    end
  end

  defp connections(%Database{} = database) do
    host = SqlitesWeb.Endpoint.host()
    port = SqlitesWeb.Endpoint.url() |> URI.parse() |> Map.get(:port)

    %{
      libsql: "libsql://#{host}:#{port}/#{database.id}?authToken=#{database.auth_token}",
      http: %{
        url: SqlitesWeb.Endpoint.url() <> "/v1/databases/#{database.id}/query",
        method: "POST",
        headers: %{authorization: "Bearer #{database.auth_token}"},
        body: %{sql: "SELECT 1", args: []}
      }
    }
  end
end
