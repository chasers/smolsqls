defmodule SmolsqlsWeb.PageController do
  use SmolsqlsWeb, :controller

  def home(conn, _params) do
    render(conn, :home, limits: platform_limits(), page_title: "Multitenant SQLite")
  end

  defp platform_limits do
    defaults = Smolsqls.Limits.defaults()

    [
      {"Databases per account", format_count(defaults.max_databases)},
      {"Size per database", format_bytes(defaults.max_size_bytes)},
      {"Backups", "daily"},
      {"Query timeout", format_ms(defaults.query_timeout_ms)},
      {"Statement timeout", format_ms(defaults.statement_timeout_ms)},
      {"Transaction lease", format_ms(defaults.txn_timeout_ms)}
    ]
  end

  defp format_count(nil), do: "unlimited"
  defp format_count(n), do: Integer.to_string(n)

  defp format_bytes(nil), do: "unlimited"

  defp format_bytes(bytes) do
    gib = 1_073_741_824
    mib = 1_048_576

    cond do
      rem(bytes, gib) == 0 -> "#{div(bytes, gib)} GiB"
      rem(bytes, mib) == 0 -> "#{div(bytes, mib)} MiB"
      true -> "#{bytes} bytes"
    end
  end

  defp format_ms(nil), do: "none"
  defp format_ms(ms) when ms >= 1000, do: "#{div(ms, 1000)}s"
  defp format_ms(ms), do: "#{ms}ms"
end
