defmodule Beamflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias Beamflow.Storage.MnesiaSetup

  @impl true
  def start(_type, _args) do
    # Iniciar Mnesia y asegurar tablas antes que cualquier supervisor
    start_mnesia()
    ensure_mnesia_tables()

    children = [
      BeamflowWeb.Telemetry,
      {Phoenix.PubSub, name: Beamflow.PubSub},
      # Registry for Circuit Breakers
      {Registry, keys: :unique, name: Beamflow.CircuitBreakerRegistry},
      # Alert System for critical notifications
      Beamflow.Engine.AlertSystem,
      # Dead Letter Queue for failed workflows
      Beamflow.Engine.DeadLetterQueue,
      # Route Loader for dynamic dispatch branches
      Beamflow.Workflows.RouteLoader,
      # Registry for Workflows
      Beamflow.Engine.Registry,
      # Start the Endpoint (http/https)
      BeamflowWeb.Endpoint,
      # Start the internal Workflow Supervisor
      Beamflow.Engine.WorkflowSupervisor
      # Start a worker by calling: Beamflow.Worker.start_link(arg)
      # {Beamflow.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Beamflow.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp start_mnesia do
    case :mnesia.start() do
      :ok ->
        Logger.info("Mnesia started successfully")
        :ok

      {:error, {:already_started, _}} ->
        Logger.debug("Mnesia already started")
        :ok

      {:error, reason} ->
        Logger.error("Failed to start Mnesia: #{inspect(reason)}")
        raise "Could not start Mnesia: #{inspect(reason)}"
    end
  end

  defp ensure_mnesia_tables do
    case MnesiaSetup.ensure_tables() do
      :ok ->
        Logger.info("Mnesia tables ready")
        :ok

      {:error, reason} ->
        Logger.warning("Could not ensure Mnesia tables: #{inspect(reason)}")
        # No fallar el arranque, las tablas pueden crearse después
        :ok
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BeamflowWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
