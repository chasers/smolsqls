# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :sqlites,
  ecto_repos: [Sqlites.Repo],
  generators: [timestamp_type: :utc_datetime],
  data_dir: "/var/lib/sqlites/data",
  infra_adapter: Sqlites.Infra.Kubernetes,
  database_idle_ttl: :timer.hours(1)

config :sqlites, Sqlites.ReadModel, enabled: true

config :sqlites, Sqlites.Limits,
  max_databases: 100,
  max_size_bytes: 1_073_741_824,
  rate_limit_rps: nil,
  query_timeout_ms: 30_000,
  statement_timeout_ms: 30_000,
  idle_ttl_ms: nil,
  max_hot_ms: nil

config :sqlites, Sqlites.ObjectStore, adapter: Sqlites.ObjectStore.S3

# Configure the endpoint
config :sqlites, SqlitesWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SqlitesWeb.ErrorHTML, json: SqlitesWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Sqlites.PubSub,
  live_view: [signing_salt: "MIoW4iP6"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  sqlites: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  sqlites: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, ["password", "token", "secret", "api_key", "auth_token"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
