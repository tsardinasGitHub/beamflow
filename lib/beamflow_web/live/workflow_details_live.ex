defmodule BeamflowWeb.WorkflowDetailsLive do
  @moduledoc """
  LiveView para visualizar los detalles de un workflow específico.

  Muestra información detallada sobre un workflow individual, incluyendo
  su estado actual, historial de eventos y datos del contexto en tiempo real.

  ## Funcionalidades

  - Estado del workflow con badge visual
  - Barra de progreso de steps
  - Historial de eventos con timestamps
  - Contexto del workflow (datos procesados)
  - Actualización en tiempo real via PubSub
  - Botón de retry para workflows fallidos
  """

  use BeamflowWeb, :live_view

  alias Beamflow.Storage.WorkflowStore
  alias Beamflow.Engine.WorkflowActor

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Suscribirse a actualizaciones de este workflow específico
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "workflow:#{id}")
    end

    socket =
      socket
      |> assign(page_title: "Workflow #{id}", workflow_id: id)
      |> load_workflow(id)
      |> load_events(id)

    {:ok, socket}
  end

  @impl true
  def handle_info({:workflow_updated, data}, socket) do
    # Actualizar con datos del PubSub (más rápido que leer de Mnesia)
    socket =
      socket
      |> assign(:workflow, data)
      |> load_events(socket.assigns.workflow_id)

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    workflow_id = socket.assigns.workflow_id

    case WorkflowActor.execute_next_step(workflow_id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Reintentando step...")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl">
      <div class="mb-6">
        <.link navigate={~p"/dashboard"} class="text-blue-600 hover:underline">
          ← Volver al Dashboard
        </.link>
      </div>

      <%= if @workflow do %>
        <div class="space-y-6">
          <!-- Header -->
          <div class="flex justify-between items-start">
            <div>
              <h1 class="text-2xl font-bold mb-1">Workflow: <%= @workflow_id %></h1>
              <p class="text-gray-500 text-sm">
                Módulo: <%= format_module(@workflow.workflow_module) %>
              </p>
            </div>
            <.status_badge status={@workflow.status} />
          </div>

          <!-- Progreso -->
          <div class="bg-white p-6 rounded-lg shadow border">
            <h2 class="text-lg font-semibold mb-4">📊 Progreso</h2>
            <.progress_detail
              current={@workflow.current_step_index}
              total={@workflow.total_steps}
              status={@workflow.status}
            />

            <%= if @workflow.status == :failed do %>
              <div class="mt-4 p-4 bg-red-50 border border-red-200 rounded-lg">
                <p class="text-red-700 font-medium mb-2">❌ Error:</p>
                <pre class="text-sm text-red-600 whitespace-pre-wrap"><%= inspect(@workflow.error, pretty: true) %></pre>
                <button
                  phx-click="retry"
                  class="mt-3 px-4 py-2 bg-red-600 text-white rounded hover:bg-red-700 transition"
                >
                  🔄 Reintentar Step
                </button>
              </div>
            <% end %>

            <%= if @workflow.status == :completed do %>
              <div class="mt-4 p-4 bg-green-50 border border-green-200 rounded-lg">
                <p class="text-green-700 font-medium">✅ Workflow completado exitosamente</p>
                <%= if @workflow.completed_at do %>
                  <p class="text-sm text-green-600 mt-1">
                    Finalizado: <%= format_datetime_full(@workflow.completed_at) %>
                  </p>
                <% end %>
              </div>
            <% end %>
          </div>

          <!-- Contexto / Datos -->
          <div class="bg-white p-6 rounded-lg shadow border">
            <h2 class="text-lg font-semibold mb-4">📋 Datos del Workflow</h2>
            <.workflow_data data={@workflow.workflow_state} />
          </div>

          <!-- Historial de Eventos -->
          <div class="bg-white p-6 rounded-lg shadow border">
            <h2 class="text-lg font-semibold mb-4">📜 Historial de Eventos</h2>
            <.events_timeline events={@events} />
          </div>

          <!-- Timestamps -->
          <div class="bg-gray-50 p-4 rounded-lg text-sm text-gray-500">
            <div class="flex gap-6">
              <span>Iniciado: <%= format_datetime_full(@workflow.started_at) %></span>
              <%= if @workflow.completed_at do %>
                <span>Completado: <%= format_datetime_full(@workflow.completed_at) %></span>
              <% end %>
            </div>
          </div>
        </div>
      <% else %>
        <div class="p-8 text-center bg-yellow-50 rounded-lg border border-yellow-200">
          <p class="text-yellow-700">⚠️ Workflow no encontrado: <%= @workflow_id %></p>
          <.link navigate={~p"/dashboard"} class="text-blue-600 hover:underline mt-2 inline-block">
            Volver al Dashboard
          </.link>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Componentes
  # ============================================================================

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    {text, class} =
      case assigns.status do
        :pending -> {"⏳ Pendiente", "bg-yellow-100 text-yellow-800 border-yellow-300"}
        :running -> {"🔄 Ejecutando", "bg-blue-100 text-blue-800 border-blue-300"}
        :completed -> {"✅ Completado", "bg-green-100 text-green-800 border-green-300"}
        :failed -> {"❌ Fallido", "bg-red-100 text-red-800 border-red-300"}
        _ -> {"❓ Desconocido", "bg-gray-100 text-gray-800 border-gray-300"}
      end

    assigns = assign(assigns, text: text, class: class)

    ~H"""
    <span class={"px-3 py-1.5 text-sm font-medium rounded-full border #{@class}"}>
      <%= @text %>
    </span>
    """
  end

  attr :current, :integer, required: true
  attr :total, :integer, required: true
  attr :status, :atom, required: true

  defp progress_detail(assigns) do
    percentage = if assigns.total > 0, do: assigns.current / assigns.total * 100, else: 0

    bar_color =
      case assigns.status do
        :completed -> "bg-green-500"
        :failed -> "bg-red-500"
        :running -> "bg-blue-500"
        _ -> "bg-gray-400"
      end

    assigns = assign(assigns, percentage: percentage, bar_color: bar_color)

    ~H"""
    <div>
      <div class="flex justify-between text-sm mb-2">
        <span>Step <%= @current %> de <%= @total %></span>
        <span class="font-medium"><%= Float.round(@percentage, 1) %>%</span>
      </div>
      <div class="h-4 bg-gray-200 rounded-full overflow-hidden">
        <div class={"h-full #{@bar_color} transition-all duration-500"} style={"width: #{@percentage}%"}>
        </div>
      </div>
    </div>
    """
  end

  attr :data, :map, required: true

  defp workflow_data(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= for {key, value} <- @data do %>
        <div class="border-b pb-3 last:border-b-0">
          <div class="text-sm font-medium text-gray-500 mb-1">
            <%= humanize_key(key) %>
          </div>
          <div class="text-gray-800">
            <.format_value value={value} />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :value, :any, required: true

  defp format_value(%{value: value} = assigns) when is_map(value) do
    ~H"""
    <pre class="text-sm bg-gray-50 p-3 rounded overflow-x-auto"><%= inspect(@value, pretty: true, limit: 50) %></pre>
    """
  end

  defp format_value(%{value: value} = assigns) when is_list(value) do
    ~H"""
    <pre class="text-sm bg-gray-50 p-3 rounded overflow-x-auto"><%= inspect(@value, pretty: true, limit: 50) %></pre>
    """
  end

  defp format_value(assigns) do
    ~H"""
    <span><%= inspect(@value) %></span>
    """
  end

  attr :events, :list, required: true

  defp events_timeline(assigns) do
    ~H"""
    <div class="space-y-3">
      <%= if @events == [] do %>
        <p class="text-gray-500 text-sm">No hay eventos registrados</p>
      <% else %>
        <%= for event <- @events do %>
          <div class="flex gap-3 items-start">
            <div class="mt-1">
              <.event_icon type={event.event_type} />
            </div>
            <div class="flex-1">
              <div class="flex justify-between items-center">
                <span class="font-medium text-sm">
                  <%= humanize_event(event.event_type) %>
                </span>
                <span class="text-xs text-gray-400">
                  <%= format_datetime(event.timestamp) %>
                </span>
              </div>
              <%= if event.data[:step] do %>
                <p class="text-sm text-gray-500">
                  Step: <%= format_step_name(event.data.step) %>
                </p>
              <% end %>
              <%= if event.data[:duration_ms] do %>
                <p class="text-xs text-gray-400">
                  Duración: <%= event.data.duration_ms %>ms
                </p>
              <% end %>
              <%= if event.data[:error] do %>
                <p class="text-xs text-red-500">
                  Error: <%= event.data.error %>
                </p>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :type, :atom, required: true

  defp event_icon(assigns) do
    icon =
      case assigns.type do
        :workflow_started -> "🚀"
        :step_started -> "▶️"
        :step_completed -> "✅"
        :step_failed -> "❌"
        :workflow_completed -> "🏁"
        :workflow_failed -> "💥"
        _ -> "📌"
      end

    assigns = assign(assigns, :icon, icon)

    ~H"""
    <span class="text-lg"><%= @icon %></span>
    """
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp load_workflow(socket, id) do
    # Primero intentar obtener del actor en memoria (más fresco)
    workflow =
      case WorkflowActor.get_state(id) do
        {:ok, state} -> state
        {:error, :not_found} ->
          # Si no está en memoria, buscar en Mnesia
          case WorkflowStore.get_workflow(id) do
            {:ok, record} -> record
            {:error, _} -> nil
          end
      end

    assign(socket, :workflow, workflow)
  end

  defp load_events(socket, id) do
    events =
      case WorkflowStore.get_events(id) do
        {:ok, events} -> events
        {:error, _} -> []
      end

    assign(socket, :events, events)
  end

  defp format_module(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp format_module(_), do: "Unknown"

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S.%f")
    |> String.slice(0, 12)
  end

  defp format_datetime(_), do: "-"

  defp format_datetime_full(nil), do: "-"

  defp format_datetime_full(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_datetime_full(_), do: "-"

  defp humanize_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize_key(key), do: to_string(key)

  defp humanize_event(:workflow_started), do: "Workflow Iniciado"
  defp humanize_event(:step_started), do: "Step Iniciado"
  defp humanize_event(:step_completed), do: "Step Completado"
  defp humanize_event(:step_failed), do: "Step Fallido"
  defp humanize_event(:workflow_completed), do: "Workflow Completado"
  defp humanize_event(:workflow_failed), do: "Workflow Fallido"
  defp humanize_event(event), do: to_string(event)

  defp format_step_name(step) when is_binary(step) do
    step
    |> String.replace("Beamflow.Domains.Insurance.Steps.", "")
    |> String.replace("Elixir.", "")
  end

  defp format_step_name(step), do: inspect(step)
end
