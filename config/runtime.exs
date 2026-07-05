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
#     PHX_SERVER=true bin/sqlites start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :sqlites, SqlitesWeb.Endpoint, server: true
end

config :sqlites, SqlitesWeb.Endpoint,
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

  config :sqlites, Sqlites.Repo,
    # ssl: true,
    url: database_url,
    # Discrete connection keys are also set because the libcluster
    # topology and the read-model replication connection build their
    # own Postgres connections from this config.
    hostname: db_uri.host,
    port: db_uri.port || 5432,
    username: db_username,
    password: List.first(db_password) || "",
    database: String.trim_leading(db_uri.path || "/sqlites", "/"),
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

  config :sqlites, SqlitesWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :sqlites, Sqlites.Secrets, key: System.get_env("TOKEN_ENCRYPTION_KEY") || secret_key_base

  config :sqlites, data_dir: System.get_env("DATA_DIR") || "/var/lib/sqlites/data"

  config :sqlites, Sqlites.ObjectStore,
    adapter: Sqlites.ObjectStore.S3,
    bucket: System.get_env("S3_BUCKET") || "sqlites-replica",
    access_key_id: System.get_env("S3_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("S3_SECRET_ACCESS_KEY"),
    endpoint: System.get_env("S3_ENDPOINT")

  config :sqlites, Sqlites.DataPlane.Litestream,
    enabled: System.get_env("LITESTREAM_ENABLED") in ~w(true 1),
    socket: System.get_env("LITESTREAM_SOCKET") || "/var/run/litestream/litestream.sock",
    replica_url_prefix: System.get_env("LITESTREAM_REPLICA_URL_PREFIX")

  config :sqlites, Sqlites.DataPlane.CacheEvictor,
    enabled: System.get_env("CACHE_EVICTION_ENABLED") in ~w(true 1),
    high_water_bytes: String.to_integer(System.get_env("CACHE_HIGH_WATER_BYTES") || "53687091200")

  config :sqlites, Sqlites.Drain.Worker, enabled: true

  if gen_rpc_port = System.get_env("GEN_RPC_PORT") do
    config :gen_rpc, tcp_server_port: String.to_integer(gen_rpc_port)
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :sqlites, SqlitesWeb.Endpoint,
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
  #     config :sqlites, SqlitesWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
