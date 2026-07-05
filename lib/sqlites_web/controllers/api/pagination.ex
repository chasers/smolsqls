defmodule SqlitesWeb.Api.Pagination do
  @moduledoc """
  Shared cursor-pagination query params: `?after=<id>&limit=<n>`.
  """

  @default_limit 100
  @max_limit 1000

  @spec opts(map()) :: {:ok, keyword()} | {:error, :invalid_limit}
  def opts(params) do
    with {:ok, limit} <- parse_limit(params["limit"]) do
      {:ok, [limit: limit, after: params["after"]]}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 -> {:ok, min(n, @max_limit)}
      _ -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(value) when is_integer(value) and value >= 1 do
    {:ok, min(value, @max_limit)}
  end

  defp parse_limit(_value), do: {:error, :invalid_limit}
end
