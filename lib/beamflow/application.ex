defmodule Beamflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias Beamflow.Database.Setup, as: DatabaseSetup

  @impl true
  def start(_type, _args) do
    # Iniciar Mnesia y configurar Amnesia Database
    start_mnesia()
    init_amnesia_database()

    children = [
      BeamflowWeb.Telemetry,
      {Phoenix.PubSub, name: Beamflow.PubSub},
      # Registry for Circuit Breakers
      {Registry, keys: :unique, name: Beamflow.CircuitBreakerRegistry},
      # Alert System for critical notifications
      Beamflow.Engine.AlertSystem,
      # Dead Letter Queue for failed workflows
      Beamflow.Engine.DeadLetterQueue,
      # Chaos Monkey for resilience testing (disabled by default)
      Beamflow.Chaos.ChaosMonkey,
      # Idempotency Validator for chaos testing
      Beamflow.Chaos.IdempotencyValidator,
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

  # Inicializa las tablas Amnesia (Workflow, Event, Idempotency, DeadLetterEntry)
  defp init_amnesia_database do
    case DatabaseSetup.init() do
      :ok ->
        Logger.info("Amnesia database initialized successfully")
        :ok

      {:error, reason} ->
        Logger.error("Could not initialize Amnesia database: #{inspect(reason)}")
        # Fallar si no podemos inicializar la BD
        raise "Could not initialize Amnesia database: #{inspect(reason)}"
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
