defmodule SqlitesWeb.Api.TokenJSON do
  @moduledoc """
  Shared rendering for `DatabaseToken` and `TenantApiKey` rows — same
  shape, different owner. The plaintext secret rides the virtual
  `token` field and is present only on create and explicit reveal
  responses; lists and updates return metadata only.
  """

  def index(%{tokens: tokens}) do
    %{data: Enum.map(tokens, &data/1)}
  end

  def show(%{token: token}) do
    %{data: data(token)}
  end

  defp data(token) do
    base = %{
      id: token.id,
      name: token.name,
      enabled: token.enabled,
      expires_at: token.expires_at,
      created_at: token.inserted_at
    }

    if is_binary(token.token) do
      Map.put(base, :token, token.token)
    else
      base
    end
  end
end
