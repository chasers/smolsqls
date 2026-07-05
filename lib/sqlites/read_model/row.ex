defmodule Sqlites.ReadModel.Row do
  @moduledoc """
  Builds control-plane structs from the text-format column values that
  both the COPY snapshot and the pgoutput feed produce.
  """

  alias Sqlites.ControlPlane.{Database, DatabaseToken, Tenant, TenantApiKey}

  @database_columns ~w(id tenant_id name status node file_path litestream_enabled snapshot_generation limits)
  @tenant_columns ~w(id name slug limits)
  @database_token_columns ~w(id database_id token_hash enabled expires_at)
  @tenant_api_key_columns ~w(id tenant_id token_hash enabled expires_at)

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
      file_path: Map.get(values, "file_path"),
      litestream_enabled: boolean(Map.get(values, "litestream_enabled")),
      snapshot_generation: integer(Map.get(values, "snapshot_generation")),
      limits: map(Map.get(values, "limits"))
    }
  end

  @spec build_tenant(%{optional(String.t()) => String.t() | nil}) :: Tenant.t()
  def build_tenant(values) do
    %Tenant{
      id: Map.fetch!(values, "id"),
      name: Map.fetch!(values, "name"),
      slug: Map.fetch!(values, "slug"),
      limits: map(Map.get(values, "limits"))
    }
  end

  @spec build_database_token(%{optional(String.t()) => String.t() | nil}) :: DatabaseToken.t()
  def build_database_token(values) do
    %DatabaseToken{
      id: Map.fetch!(values, "id"),
      database_id: Map.fetch!(values, "database_id"),
      token_hash: Map.fetch!(values, "token_hash"),
      enabled: boolean(Map.get(values, "enabled")),
      expires_at: datetime(Map.get(values, "expires_at"))
    }
  end

  @spec build_tenant_api_key(%{optional(String.t()) => String.t() | nil}) :: TenantApiKey.t()
  def build_tenant_api_key(values) do
    %TenantApiKey{
      id: Map.fetch!(values, "id"),
      tenant_id: Map.fetch!(values, "tenant_id"),
      token_hash: Map.fetch!(values, "token_hash"),
      enabled: boolean(Map.get(values, "enabled")),
      expires_at: datetime(Map.get(values, "expires_at"))
    }
  end

  defp boolean("t"), do: true
  defp boolean("true"), do: true
  defp boolean(_), do: false

  defp integer(nil), do: 0
  defp integer(value), do: String.to_integer(value)

  defp datetime(nil), do: nil

  defp datetime(value) do
    iso = String.replace(value, " ", "T")
    iso = if Regex.match?(~r/[+-]\d\d$/, iso), do: iso <> ":00", else: iso

    case DateTime.from_iso8601(iso) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
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
