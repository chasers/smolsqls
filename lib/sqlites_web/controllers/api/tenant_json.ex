defmodule SqlitesWeb.Api.TenantJSON do
  alias Sqlites.ControlPlane.Tenant

  def show(%{tenant: tenant, include_api_key: include_api_key}) do
    %{data: data(tenant, include_api_key)}
  end

  defp data(%Tenant{} = tenant, include_api_key) do
    base = %{
      id: tenant.id,
      name: tenant.name,
      slug: tenant.slug,
      limits: Sqlites.Limits.resolve(nil, tenant),
      created_at: tenant.inserted_at
    }

    if include_api_key and is_binary(tenant.api_key) do
      Map.put(base, :api_key, tenant.api_key)
    else
      base
    end
  end
end
