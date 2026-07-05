defmodule SqlitesWeb.Router do
  use SqlitesWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SqlitesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug SqlitesWeb.Api.AuthPlug
  end

  scope "/", SqlitesWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/login", SessionController, :create
    post "/signup", SessionController, :signup
    post "/logout", SessionController, :delete

    live "/dashboard", DatabaseLive.Index, :index
  end

  scope "/v1", SqlitesWeb.Api do
    pipe_through :api

    get "/", IndexController, :index
    post "/tenants", TenantController, :create
    post "/databases/:database_id/query", QueryController, :create
  end

  scope "/v2", SqlitesWeb.Hrana do
    pipe_through :api

    post "/pipeline", PipelineController, :create
  end

  scope "/v1", SqlitesWeb.Api do
    pipe_through [:api, :api_authenticated]

    get "/tenant", TenantController, :show
    patch "/tenant", TenantController, :update
    delete "/tenant", TenantController, :delete

    resources "/tenant/keys", TenantApiKeyController,
      only: [:index, :create, :update, :delete],
      name: :tenant_api_key

    post "/tenant/keys/:id/reveal", TenantApiKeyController, :reveal

    resources "/databases", DatabaseController, only: [:index, :create, :show, :update, :delete]

    resources "/databases/:database_id/tokens", DatabaseTokenController,
      only: [:index, :create, :update, :delete],
      name: :database_token

    post "/databases/:database_id/tokens/:id/reveal", DatabaseTokenController, :reveal

    get "/databases/:database_id/backups", BackupController, :index
    post "/databases/:database_id/backups", BackupController, :create
    post "/databases/:database_id/restore", BackupController, :restore
  end
end
