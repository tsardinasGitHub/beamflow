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

    # Dashboard Ejecutivo como página principal
    live "/", DashboardLive

    # Explorador de Workflows - Con filtros y streams
    live "/workflows", WorkflowExplorerLive
    live "/workflows/:id", WorkflowDetailsLive
    live "/workflows/:id/graph", WorkflowGraphLive

    # Panel de Resiliencia - Circuit Breakers, DLQ, Sagas
    live "/resilience", ResilienceLive

    # Centro de Control de Chaos Engineering
    live "/chaos", ChaosLive

    # Dashboard de Analytics - Métricas y tendencias
    live "/analytics", AnalyticsLive
  end

  # API REST para exportación programática
  scope "/api", BeamflowWeb do
    pipe_through :api

    get "/analytics/export", AnalyticsController, :export
  end

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
