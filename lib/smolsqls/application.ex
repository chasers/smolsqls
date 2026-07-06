defmodule Smolsqls.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Smolsqls.DataPlane.Registry.init()

    children =
      [
        SmolsqlsWeb.Telemetry,
        Smolsqls.Repo,
        {Cluster.Supervisor, [cluster_topologies(), [name: Smolsqls.ClusterSupervisor]]},
        {Phoenix.PubSub, name: Smolsqls.PubSub},
        Smolsqls.RateLimiter,
        Smolsqls.SignupLimiter,
        Smolsqls.DataPlane.Supervisor,
        Smolsqls.DataPlane.Reconciler
      ] ++
        read_model_children() ++
        enabled_child(Smolsqls.DataPlane.CacheEvictor) ++
        enabled_child(Smolsqls.DataPlane.Fence) ++
        enabled_child(Smolsqls.Drain.Worker) ++
        enabled_child(Smolsqls.Backups.Sweeper) ++
        [SmolsqlsWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Smolsqls.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SmolsqlsWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp enabled_child(module) do
    if Application.get_env(:smolsqls, module, [])[:enabled] do
      [{module, []}]
    else
      []
    end
  end

  defp read_model_children do
    if Application.get_env(:smolsqls, Smolsqls.ReadModel, [])[:enabled] do
      [{Smolsqls.ReadModel, []}, Smolsqls.ReadModel.Replication]
    else
      []
    end
  end

  defp cluster_topologies do
    Application.get_env(:libcluster, :topologies) || default_topologies()
  end

  defp default_topologies do
    repo_config = Application.fetch_env!(:smolsqls, Smolsqls.Repo)

    [
      postgres: [
        strategy: LibclusterPostgres.Strategy,
        config:
          repo_config
          |> Keyword.take([:hostname, :username, :password, :database, :port])
          |> Keyword.merge(
            port: repo_config[:port] || 5432,
            parameters: [],
            channel_name: "smolsqls_cluster"
          )
      ]
    ]
  end
end
