defmodule Sqlites.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Sqlites.DataPlane.Registry.init()

    children =
      [
        SqlitesWeb.Telemetry,
        Sqlites.Repo,
        {Cluster.Supervisor, [cluster_topologies(), [name: Sqlites.ClusterSupervisor]]},
        {Phoenix.PubSub, name: Sqlites.PubSub},
        Sqlites.RateLimiter,
        Sqlites.DataPlane.Supervisor,
        Sqlites.DataPlane.Reconciler
      ] ++
        read_model_children() ++
        enabled_child(Sqlites.DataPlane.CacheEvictor) ++
        enabled_child(Sqlites.Drain.Worker) ++
        [SqlitesWeb.Endpoint]

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

  defp enabled_child(module) do
    if Application.get_env(:sqlites, module, [])[:enabled] do
      [{module, []}]
    else
      []
    end
  end

  defp read_model_children do
    if Application.get_env(:sqlites, Sqlites.ReadModel, [])[:enabled] do
      [{Sqlites.ReadModel, []}, Sqlites.ReadModel.Replication]
    else
      []
    end
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
