import Config

config :smolsqls,
  data_dir: Path.expand("../.data/test#{System.get_env("MIX_TEST_PARTITION")}", __DIR__),
  infra_adapter: Smolsqls.Infra.Local,
  reconcile_on_boot: false

config :smolsqls, Smolsqls.ReadModel, enabled: false

config :smolsqls, SmolsqlsWeb.Telemetry, backup_sla_poller: false

config :smolsqls, Smolsqls.ObjectStore, adapter: Smolsqls.ObjectStore.Local

config :gen_rpc, tcp_server_port: 15369

config :libcluster, topologies: []

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :smolsqls, Smolsqls.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "smolsqls_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :smolsqls, SmolsqlsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "JW4miBfU07mU4e649ZIcazF61oSMrbrtIp7924lVO/ZLQt27Iqzsu4f8EsB1yMO2",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :smolsqls, Smolsqls.Secrets, key: "test-only-token-encryption-key"

config :smolsqls, reconciler_membership_timeout: 0
