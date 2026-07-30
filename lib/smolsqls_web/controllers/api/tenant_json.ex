defmodule SmolsqlsWeb.Api.TenantJSON do
  alias Smolsqls.ControlPlane.Tenant

  def show(%{tenant: tenant, limits: limits, include_api_key: include_api_key}) do
    %{data: data(tenant, limits, include_api_key)}
  end

  defp data(%Tenant{} = tenant, limits, include_api_key) do
    base = %{
      id: tenant.id,
      name: tenant.name,
      slug: tenant.slug,
      limits: limits,
      created_at: tenant.inserted_at
    }

    if include_api_key and is_binary(tenant.api_key) do
      Map.put(base, :api_key, tenant.api_key)
    else
      base
    end
  end
end
