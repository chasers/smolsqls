defmodule SmolsqlsWeb.ConnectionStrings do
  @moduledoc """
  Builds the client connection strings for a database from the canonical
  endpoint host. The **global** host (`alpha.daisy.smolsqls.com`) is the
  configured `PHX_HOST`; the global external load balancer geo-routes it to
  the nearest region, and any node proxies to the owner. A **regional** host
  splices a database's region slug in as the second label
  (`alpha.gcp-us-central1.daisy.smolsqls.com`) to pin traffic to the owning
  region for debugging.

  The default port for the scheme (443/https, 80/http) is omitted so hosts
  behind a standard load balancer read cleanly.
  """

  alias SmolsqlsWeb.Endpoint

  @spec global_host() :: String.t()
  def global_host, do: Endpoint.host()

  @spec regional_host(String.t()) :: String.t()
  def regional_host(region) when is_binary(region) do
    case String.split(global_host(), ".") do
      [first | rest] -> Enum.join([first, region | rest], ".")
      _ -> global_host()
    end
  end

  @spec libsql_url(String.t(), String.t()) :: String.t()
  def libsql_url(host, token), do: "libsql://#{host}#{port_suffix()}?authToken=#{token}"

  @spec http_base(String.t()) :: String.t()
  def http_base(host), do: "#{scheme()}://#{host}#{port_suffix()}"

  @spec ws_base(String.t()) :: String.t()
  def ws_base(host) do
    ws = if scheme() == "https", do: "wss", else: "ws"
    "#{ws}://#{host}#{port_suffix()}"
  end

  @spec scheme() :: String.t()
  def scheme, do: uri().scheme

  defp uri, do: URI.parse(Endpoint.url())

  defp port_suffix do
    u = uri()

    cond do
      u.scheme == "https" and u.port == 443 -> ""
      u.scheme == "http" and u.port == 80 -> ""
      is_nil(u.port) -> ""
      true -> ":#{u.port}"
    end
  end
end
