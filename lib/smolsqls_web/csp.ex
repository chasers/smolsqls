defmodule SmolsqlsWeb.CSP do
  @moduledoc """
  Refines the browser Content-Security-Policy with a per-request nonce for
  the one inline bootstrap script in the root layout (theme selection, which
  must run before first paint). The router's `put_secure_browser_headers`
  sets a static baseline CSP (`script-src 'self'`) — that is the safe
  fallback and what static analysis sees; this plug runs after it and
  overwrites the header with an otherwise-identical policy whose
  `script-src` also carries `'nonce-<n>'`. LiveView never injects further
  inline scripts, so the nonce is only needed on the dead render. The nonce
  is stashed in `conn.assigns` for the layout to stamp onto that `<script>`.
  """

  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'self'",
        "frame-ancestors 'self'"
      ],
      "; "
    )
  end
end
