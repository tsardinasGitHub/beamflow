defmodule BeamflowWeb.Router do
  use BeamflowWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BeamflowWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BeamflowWeb do
    pipe_through :browser

    # Página principal redirige al dashboard ejecutivo
    get "/", PageController, :home

    # Dashboard Ejecutivo - Vista principal con KPIs
    live "/dashboard", DashboardLive

    # Explorador de Workflows - Con filtros y streams
    live "/workflows", WorkflowExplorerLive
    live "/workflows/:id", WorkflowDetailsLive

    # Panel de Resiliencia - Circuit Breakers, DLQ, Sagas
    live "/resilience", ResilienceLive

    # Centro de Control de Chaos Engineering
    live "/chaos", ChaosLive

    # Legacy: mantener compatibilidad con dashboard antiguo
    live "/dashboard/legacy", WorkflowDashboardLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", BeamflowWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard only for development
  #
  # If you want to use the LiveDashboard in production, you should put
  # it behind authentication and allow only admins to access it.
  # If your application does not have an admins-only section yet,
  # you can use Plug.BasicAuth to set up some basic authentication.
  # as long as you are also using SSL (which you should anyway).
  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BeamflowWeb.Telemetry
    end
  end
end
