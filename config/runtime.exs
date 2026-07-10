import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/smolsqls start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :smolsqls, SmolsqlsWeb.Endpoint, server: true
end

config :smolsqls, SmolsqlsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  db_uri = URI.parse(database_url)

  [db_username | db_password] = String.split(db_uri.userinfo || "postgres", ":", parts: 2)

  config :smolsqls, Smolsqls.Repo,
    # ssl: true,
    url: database_url,
    # Discrete connection keys are also set because the libcluster
    # topology and the read-model replication connection build their
    # own Postgres connections from this config.
    hostname: db_uri.host,
    port: db_uri.port || 5432,
    username: db_username,
    password: List.first(db_password) || "",
    database: String.trim_leading(db_uri.path || "/smolsqls", "/"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  url_port = String.to_integer(System.get_env("PHX_URL_PORT") || "443")
  url_scheme = System.get_env("PHX_URL_SCHEME") || "https"

  config :smolsqls, SmolsqlsWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :smolsqls, Smolsqls.Secrets,
    key: System.get_env("TOKEN_ENCRYPTION_KEY") || secret_key_base

  config :smolsqls, data_dir: System.get_env("DATA_DIR") || "/var/lib/smolsqls/data"

  config :smolsqls,
    region: System.get_env("REGION"),
    regions:
      (System.get_env("REGIONS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1),
    default_region: System.get_env("DEFAULT_REGION")

  config :smolsqls, Smolsqls.ObjectStore,
    adapter: Smolsqls.ObjectStore.S3,
    bucket: System.get_env("S3_BUCKET") || "smolsqls-replica",
    access_key_id: System.get_env("S3_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("S3_SECRET_ACCESS_KEY"),
    endpoint: System.get_env("S3_ENDPOINT")

  config :smolsqls, Smolsqls.DataPlane.Litestream,
    enabled: System.get_env("LITESTREAM_ENABLED") in ~w(true 1),
    socket: System.get_env("LITESTREAM_SOCKET") || "/var/run/litestream/litestream.sock",
    replica_url_prefix: System.get_env("LITESTREAM_REPLICA_URL_PREFIX")

  config :smolsqls, Smolsqls.DataPlane.CacheEvictor,
    enabled: System.get_env("CACHE_EVICTION_ENABLED") in ~w(true 1),
    high_water_bytes: String.to_integer(System.get_env("CACHE_HIGH_WATER_BYTES") || "53687091200")

  config :smolsqls, Smolsqls.Drain.Worker, enabled: true

  config :smolsqls, Smolsqls.DataPlane.Fence, enabled: true

  config :smolsqls, Smolsqls.Backups.Sweeper, enabled: true

  config :smolsqls, Smolsqls.ExpirySweeper, enabled: true

  if gen_rpc_port = System.get_env("GEN_RPC_PORT") do
    config :gen_rpc, tcp_server_port: String.to_integer(gen_rpc_port)
  end

  # Inter-node query traffic over TLS. Certificates are per node
  # (gen_rpc verifies the peer certificate CN against the dialed node
  # name), mounted from a k8s secret; scripts/gen-dev-certs.sh
  # generates a dev CA + node certs for the kind overlay.
  if System.get_env("GEN_RPC_TLS") in ~w(true 1) do
    tls_dir = System.get_env("GEN_RPC_TLS_DIR") || "/etc/smolsqls/gen-rpc-tls"

    pod_name =
      System.get_env("POD_NAME") || System.get_env("HOSTNAME") ||
        raise "GEN_RPC_TLS requires POD_NAME"

    ssl_options = [
      certfile: Path.join(tls_dir, pod_name <> ".pem"),
      keyfile: Path.join(tls_dir, pod_name <> ".key"),
      cacertfile: Path.join(tls_dir, "ca.pem")
    ]

    ssl_port = String.to_integer(System.get_env("GEN_RPC_SSL_PORT") || "5870")

    config :gen_rpc,
      default_client_driver: :ssl,
      tcp_server_port: false,
      ssl_server_port: ssl_port,
      ssl_client_port: ssl_port,
      ssl_client_options: ssl_options,
      ssl_server_options: ssl_options
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :smolsqls, SmolsqlsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :smolsqls, SmolsqlsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
