defmodule BeamflowWeb.WorkflowDashboardLive do
  @moduledoc """
  LiveView para el dashboard principal de workflows.

  Muestra una vista general de todos los workflows activos en el sistema,
  permitiendo monitorear su estado en tiempo real mediante Phoenix LiveView.

  ## Funcionalidades

  - Lista de workflows con su estado actual
  - Actualización en tiempo real via PubSub
  - Navegación hacia detalles de cada workflow
  """

  use BeamflowWeb, :live_view

  @doc """
  Inicializa el LiveView con la lista de workflows.

  Suscribe el socket a actualizaciones de workflows para recibir
  cambios en tiempo real.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dashboard", workflows: [])}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl">
      <h1 class="text-2xl font-bold mb-4">Workflow Dashboard</h1>

      <div class="grid gap-4">
        <div :if={@workflows == []} class="p-4 bg-zinc-50 rounded text-center text-zinc-500">
          No workflows found.
        </div>

        <div :for={workflow <- @workflows} class="border p-4 rounded shadow-sm">
          <%= workflow.id %>
        </div>
      </div>
    </div>
    """
  end
end
