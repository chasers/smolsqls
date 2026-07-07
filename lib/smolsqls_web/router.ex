defmodule SmolsqlsWeb.Router do
  use SmolsqlsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SmolsqlsWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers,
         %{
           "content-security-policy" =>
             "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
         }

    plug SmolsqlsWeb.CSP
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug SmolsqlsWeb.Api.AuthPlug
  end

  scope "/", SmolsqlsWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/login", SessionController, :create
    post "/signup", SessionController, :signup
    post "/logout", SessionController, :delete

    live "/dashboard", DatabaseLive.Index, :index
    live "/account", AccountLive.Index, :index
  end

  scope "/v1", SmolsqlsWeb.Api do
    pipe_through :api

    get "/", IndexController, :index
    post "/tenants", TenantController, :create
    post "/databases/:database_id/query", QueryController, :create
  end

  scope "/v2", SmolsqlsWeb.Hrana do
    pipe_through :api

    post "/pipeline", PipelineController, :create
  end

  scope "/", SmolsqlsWeb do
    get "/metrics", MetricsController, :index
  end

  scope "/v1", SmolsqlsWeb.Api do
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
