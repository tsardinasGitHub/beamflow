defmodule BeamflowWeb.WorkflowDashboardLive do
  @moduledoc """
  LiveView para el dashboard principal de workflows.

  Muestra una vista general de todos los workflows en el sistema,
  permitiendo monitorear su estado en tiempo real mediante Phoenix LiveView
  y PubSub.

  ## Funcionalidades

  - Lista de workflows con estado, progreso y timestamps
  - Actualización en tiempo real via PubSub
  - Estadísticas generales (pendientes, corriendo, completados, fallidos)
  - Navegación hacia detalles de cada workflow
  - Botón para crear nuevo workflow de prueba
  """

  use BeamflowWeb, :live_view

  alias Beamflow.Storage.WorkflowStore
  alias Beamflow.Engine.WorkflowSupervisor
  alias Beamflow.Domains.Insurance.InsuranceWorkflow

  @impl true
  def mount(_params, _session, socket) do
    # Suscribirse a actualizaciones de workflows
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "workflows")
    end

    socket =
      socket
      |> assign(page_title: "Dashboard")
      |> load_workflows()
      |> load_stats()

    {:ok, socket}
  end

  @impl true
  def handle_info({:workflow_updated, _data}, socket) do
    # Recargar datos cuando hay actualización
    socket =
      socket
      |> load_workflows()
      |> load_stats()

    {:noreply, socket}
  end

  @impl true
  def handle_event("create_test_workflow", _params, socket) do
    # Crear un workflow de prueba
    workflow_id = "req-#{:rand.uniform(9999)}"
    user_num = :rand.uniform(100)

    params = %{
      "applicant_name" => "Test User #{user_num}",
      "applicant_email" => "test.user.#{user_num}@beamflow.dev",
      "dni" => "#{:rand.uniform(99_999_999) |> Integer.to_string() |> String.pad_leading(8, "0")}",
      "vehicle_model" => "Toyota Corolla 2020",
      "vehicle_year" => "2020",
      "vehicle_plate" => "TST-#{:rand.uniform(999)}"
    }

    case WorkflowSupervisor.start_workflow(InsuranceWorkflow, workflow_id, params) do
      {:ok, _pid} ->
        socket =
          socket
          |> put_flash(:info, "Workflow #{workflow_id} iniciado")
          |> load_workflows()
          |> load_stats()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl">
      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-bold">🚀 Workflow Dashboard</h1>
        <button
          phx-click="create_test_workflow"
          class="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition"
        >
          + Nuevo Workflow de Prueba
        </button>
      </div>

      <!-- Estadísticas -->
      <div class="grid grid-cols-4 gap-4 mb-6">
        <.stat_card label="Pendientes" value={@stats.pending} color="yellow" />
        <.stat_card label="En Ejecución" value={@stats.running} color="blue" />
        <.stat_card label="Completados" value={@stats.completed} color="green" />
        <.stat_card label="Fallidos" value={@stats.failed} color="red" />
      </div>

      <!-- Lista de Workflows -->
      <div class="bg-white rounded-lg shadow overflow-hidden">
        <table class="w-full">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-sm font-semibold text-gray-600">ID</th>
              <th class="px-4 py-3 text-left text-sm font-semibold text-gray-600">Módulo</th>
              <th class="px-4 py-3 text-left text-sm font-semibold text-gray-600">Estado</th>
              <th class="px-4 py-3 text-left text-sm font-semibold text-gray-600">Progreso</th>
              <th class="px-4 py-3 text-left text-sm font-semibold text-gray-600">Actualizado</th>
              <th class="px-4 py-3 text-left text-sm font-semibold text-gray-600"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :if={@workflows == []} class="text-center text-gray-500">
              <td colspan="6" class="px-4 py-8">
                No hay workflows registrados. ¡Crea uno de prueba!
              </td>
            </tr>
            <tr :for={wf <- @workflows} class="hover:bg-gray-50">
              <td class="px-4 py-3 font-mono text-sm"><%= wf.id %></td>
              <td class="px-4 py-3 text-sm"><%= format_module(wf.workflow_module) %></td>
              <td class="px-4 py-3">
                <.status_badge status={wf.status} />
              </td>
              <td class="px-4 py-3">
                <.progress_bar current={wf.current_step_index} total={wf.total_steps} />
              </td>
              <td class="px-4 py-3 text-sm text-gray-500">
                <%= format_datetime(wf.updated_at) %>
              </td>
              <td class="px-4 py-3">
                <.link
                  navigate={~p"/workflows/#{wf.id}"}
                  class="text-blue-600 hover:underline text-sm"
                >
                  Ver detalles →
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Componentes
  # ============================================================================

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :color, :string, required: true

  defp stat_card(assigns) do
    color_classes = %{
      "yellow" => "bg-yellow-50 text-yellow-700 border-yellow-200",
      "blue" => "bg-blue-50 text-blue-700 border-blue-200",
      "green" => "bg-green-50 text-green-700 border-green-200",
      "red" => "bg-red-50 text-red-700 border-red-200"
    }

    assigns = assign(assigns, :color_class, color_classes[assigns.color])

    ~H"""
    <div class={"p-4 rounded-lg border #{@color_class}"}>
      <div class="text-3xl font-bold"><%= @value %></div>
      <div class="text-sm opacity-75"><%= @label %></div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    {text, class} =
      case assigns.status do
        :pending -> {"Pendiente", "bg-yellow-100 text-yellow-800"}
        :running -> {"Ejecutando", "bg-blue-100 text-blue-800"}
        :completed -> {"Completado", "bg-green-100 text-green-800"}
        :failed -> {"Fallido", "bg-red-100 text-red-800"}
        _ -> {"Desconocido", "bg-gray-100 text-gray-800"}
      end

    assigns = assign(assigns, text: text, class: class)

    ~H"""
    <span class={"px-2 py-1 text-xs font-medium rounded-full #{@class}"}>
      <%= @text %>
    </span>
    """
  end

  attr :current, :integer, required: true
  attr :total, :integer, required: true

  defp progress_bar(assigns) do
    percentage = if assigns.total > 0, do: assigns.current / assigns.total * 100, else: 0
    assigns = assign(assigns, :percentage, percentage)

    ~H"""
    <div class="flex items-center gap-2">
      <div class="flex-1 h-2 bg-gray-200 rounded-full overflow-hidden">
        <div class="h-full bg-blue-500 transition-all" style={"width: #{@percentage}%"}></div>
      </div>
      <span class="text-xs text-gray-500 w-12"><%= @current %>/<%= @total %></span>
    </div>
    """
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp load_workflows(socket) do
    case WorkflowStore.list_workflows(limit: 50) do
      {:ok, workflows} -> assign(socket, :workflows, workflows)
      {:error, _} -> assign(socket, :workflows, [])
    end
  end

  defp load_stats(socket) do
    stats = WorkflowStore.count_by_status()
    assign(socket, :stats, stats)
  end

  defp format_module(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
  end

  defp format_module(_), do: "Unknown"

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_datetime(_), do: "-"
end
