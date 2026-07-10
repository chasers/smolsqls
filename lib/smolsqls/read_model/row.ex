defmodule Smolsqls.ReadModel.Row do
  @moduledoc """
  Builds control-plane structs from the text-format column values that
  both the COPY snapshot and the pgoutput feed produce.
  """

  alias Smolsqls.ControlPlane.{Database, DatabaseToken, Tenant, TenantApiKey}

  @database_columns ~w(id tenant_id name status node region cloud file_path litestream_enabled snapshot_generation limits source_database_id branch_point_at expires_at inserted_at updated_at)
  @tenant_columns ~w(id name slug limits inserted_at updated_at)
  @database_token_columns ~w(id database_id token_hash enabled expires_at inserted_at updated_at)
  @tenant_api_key_columns ~w(id tenant_id token_hash enabled expires_at inserted_at updated_at)

  def database_columns, do: @database_columns
  def tenant_columns, do: @tenant_columns
  def database_token_columns, do: @database_token_columns
  def tenant_api_key_columns, do: @tenant_api_key_columns

  @spec build_database(%{optional(String.t()) => String.t() | nil}) :: Database.t()
  def build_database(values) do
    %Database{
      id: Map.fetch!(values, "id"),
      tenant_id: Map.fetch!(values, "tenant_id"),
      name: Map.fetch!(values, "name"),
      status: status(Map.fetch!(values, "status")),
      node: Map.get(values, "node"),
      region: Map.get(values, "region"),
      cloud: Map.get(values, "cloud"),
      file_path: Map.get(values, "file_path"),
      litestream_enabled: boolean(Map.get(values, "litestream_enabled")),
      snapshot_generation: integer(Map.get(values, "snapshot_generation")),
      limits: map(Map.get(values, "limits")),
      source_database_id: Map.get(values, "source_database_id"),
      branch_point_at: datetime(Map.get(values, "branch_point_at")),
      expires_at: datetime(Map.get(values, "expires_at")),
      inserted_at: datetime(Map.get(values, "inserted_at")),
      updated_at: datetime(Map.get(values, "updated_at"))
    }
  end

  @spec build_tenant(%{optional(String.t()) => String.t() | nil}) :: Tenant.t()
  def build_tenant(values) do
    %Tenant{
      id: Map.fetch!(values, "id"),
      name: Map.fetch!(values, "name"),
      slug: Map.fetch!(values, "slug"),
      limits: map(Map.get(values, "limits")),
      inserted_at: datetime(Map.get(values, "inserted_at")),
      updated_at: datetime(Map.get(values, "updated_at"))
    }
  end

  @spec build_database_token(%{optional(String.t()) => String.t() | nil}) :: DatabaseToken.t()
  def build_database_token(values) do
    %DatabaseToken{
      id: Map.fetch!(values, "id"),
      database_id: Map.fetch!(values, "database_id"),
      token_hash: Map.fetch!(values, "token_hash"),
      enabled: boolean(Map.get(values, "enabled")),
      expires_at: datetime(Map.get(values, "expires_at")),
      inserted_at: datetime(Map.get(values, "inserted_at")),
      updated_at: datetime(Map.get(values, "updated_at"))
    }
  end

  @spec build_tenant_api_key(%{optional(String.t()) => String.t() | nil}) :: TenantApiKey.t()
  def build_tenant_api_key(values) do
    %TenantApiKey{
      id: Map.fetch!(values, "id"),
      tenant_id: Map.fetch!(values, "tenant_id"),
      token_hash: Map.fetch!(values, "token_hash"),
      enabled: boolean(Map.get(values, "enabled")),
      expires_at: datetime(Map.get(values, "expires_at")),
      inserted_at: datetime(Map.get(values, "inserted_at")),
      updated_at: datetime(Map.get(values, "updated_at"))
    }
  end

  defp boolean("t"), do: true
  defp boolean("true"), do: true
  defp boolean(_), do: false

  defp integer(nil), do: 0
  defp integer(value), do: String.to_integer(value)

  defp datetime(nil), do: nil

  defp datetime(value) do
    iso = value |> String.replace(" ", "T") |> ensure_offset()

    case DateTime.from_iso8601(iso) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp ensure_offset(iso) do
    cond do
      Regex.match?(~r/[+-]\d\d$/, iso) -> iso <> ":00"
      Regex.match?(~r/([+-]\d\d:\d\d|Z)$/, iso) -> iso
      true -> iso <> "Z"
    end
  end

  defp map(nil), do: %{}

  defp map(json) do
    case Jason.decode(json) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp status("pending"), do: :pending
  defp status("active"), do: :active
  defp status("deleting"), do: :deleting
  defp status("error"), do: :error
end
