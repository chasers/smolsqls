defmodule Sqlites.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Sqlites.DataPlane.Registry.init()

    children = [
      SqlitesWeb.Telemetry,
      Sqlites.Repo,
      {Cluster.Supervisor, [cluster_topologies(), [name: Sqlites.ClusterSupervisor]]},
      {Phoenix.PubSub, name: Sqlites.PubSub},
      Sqlites.DataPlane.Supervisor,
      Sqlites.DataPlane.Reconciler,
      SqlitesWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sqlites.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SqlitesWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp cluster_topologies do
    Application.get_env(:libcluster, :topologies) || default_topologies()
  end

  defp default_topologies do
    repo_config = Application.fetch_env!(:sqlites, Sqlites.Repo)

    [
      postgres: [
        strategy: LibclusterPostgres.Strategy,
        config:
          repo_config
          |> Keyword.take([:hostname, :username, :password, :database, :port])
          |> Keyword.merge(
            port: repo_config[:port] || 5432,
            parameters: [],
            channel_name: "sqlites_cluster"
          )
      ]
    ]
  end
end
