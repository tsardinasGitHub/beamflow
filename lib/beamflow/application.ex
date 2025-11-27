defmodule Beamflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BeamflowWeb.Telemetry,
      {Phoenix.PubSub, name: Beamflow.PubSub},
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BeamflowWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
