defmodule Smolsqls.ReadModel.Row do
  @moduledoc """
  Builds control-plane structs from the text-format column values the
  pgoutput feed produces.

  Only the columns in `Smolsqls.ReadModel.Projection` are read — the same
  set `Smolsqls.ReadModel.Source` selects — so a row built here is shaped
  exactly like one loaded from Postgres on a cache miss. Non-projected
  fields stay `nil` and must not be relied on;
  `Smolsqls.ReadModel.ProjectionTest` fails if the two paths drift.
  """

  alias Smolsqls.ControlPlane.{Database, DatabaseToken, Tenant, TenantApiKey}

  @spec build_database(%{optional(String.t()) => String.t() | nil}) :: Database.t()
  def build_database(values) do
    %Database{
      id: Map.fetch!(values, "id"),
      tenant_id: Map.fetch!(values, "tenant_id"),
      status: status(Map.get(values, "status")),
      node: Map.get(values, "node"),
      region: Map.get(values, "region"),
      cloud: Map.get(values, "cloud"),
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
      name: Map.get(values, "name"),
      slug: Map.get(values, "slug"),
      limits: map(Map.get(values, "limits")),
      inserted_at: datetime(Map.get(values, "inserted_at"))
    }
  end

  @spec build_database_token(%{optional(String.t()) => String.t() | nil}) :: DatabaseToken.t()
  def build_database_token(values) do
    %DatabaseToken{
      id: Map.get(values, "id"),
      database_id: Map.get(values, "database_id"),
      token_hash: Map.fetch!(values, "token_hash"),
      enabled: boolean(Map.get(values, "enabled")),
      expires_at: datetime(Map.get(values, "expires_at"))
    }
  end

  @spec build_tenant_api_key(%{optional(String.t()) => String.t() | nil}) :: TenantApiKey.t()
  def build_tenant_api_key(values) do
    %TenantApiKey{
      id: Map.get(values, "id"),
      tenant_id: Map.get(values, "tenant_id"),
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
  defp status("moving"), do: :moving
  defp status("deleting"), do: :deleting
  defp status("error"), do: :error
  defp status(_other), do: :pending
end
