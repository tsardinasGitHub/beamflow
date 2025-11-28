defmodule BeamflowWeb.WorkflowGraphLive do
  @moduledoc """
  LiveView para visualización interactiva de workflows como grafos SVG.

  Muestra el workflow como un diagrama de nodos conectados donde:
  - Cada step es un nodo rectangular con el nombre del módulo
  - Las conexiones muestran el flujo entre steps
  - Los colores indican el estado de ejecución de cada step
  - Click en un nodo muestra detalles del step

  ## Estados Visuales

  - **Pendiente** (gris): Step aún no ejecutado
  - **Ejecutando** (azul pulsante): Step en ejecución actual
  - **Completado** (verde): Step ejecutado exitosamente
  - **Fallido** (rojo): Step que falló

  ## Interactividad

  - Click en nodo: Muestra panel de detalles del step
  - Hover en nodo: Resalta conexiones
  - Actualización en tiempo real via PubSub
  """

  use BeamflowWeb, :live_view

  alias Beamflow.Storage.WorkflowStore
  alias Beamflow.Engine.WorkflowActor
  alias Beamflow.Workflows.Graph

  # Configuración del layout
  @node_width 200
  @node_height 60
  @node_spacing_x 280
  # @node_spacing_y 100 # Reservado para layout vertical futuro
  @padding 40

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "workflow:#{id}")
    end

    socket =
      socket
      |> assign(
        page_title: "Grafo: #{id}",
        workflow_id: id,
        selected_node: nil,
        show_details: false,
        step_timings: %{},
        step_attempts: [],
        all_events: []
      )
      |> load_workflow(id)
      |> load_all_events(id)
      |> load_step_timings_from_events()
      |> build_graph_data()

    {:ok, socket}
  end

  @impl true
  def handle_info({:workflow_updated, data}, socket) do
    socket =
      socket
      |> assign(:workflow, data)
      |> build_graph_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_node", %{"node-id" => node_id}, socket) do
    node = Enum.find(socket.assigns.nodes, &(&1.id == node_id))
    
    # Cargar historial de intentos para este step desde todos los eventos
    step_attempts = if node do
      get_step_attempts_from_events(socket.assigns.all_events, node.index)
    else
      []
    end

    socket =
      socket
      |> assign(
        selected_node: node,
        show_details: true,
        step_attempts: step_attempts
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply, assign(socket, show_details: false)}
  end

  @impl true
  def handle_event("zoom_in", _params, socket) do
    {:noreply, push_event(socket, "zoom_in", %{})}
  end

  @impl true
  def handle_event("zoom_out", _params, socket) do
    {:noreply, push_event(socket, "zoom_out", %{})}
  end

  @impl true
  def handle_event("zoom_reset", _params, socket) do
    {:noreply, push_event(socket, "zoom_reset", %{})}
  end

  @impl true
  def handle_event("zoom_fit", _params, socket) do
    {:noreply, push_event(socket, "zoom_fit", %{})}
  end

  @impl true
  def handle_event("export_svg", _params, socket) do
    {:noreply, push_event(socket, "export_svg", %{filename: "workflow-#{socket.assigns.workflow_id}.svg"})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-900 via-purple-900 to-slate-900">
      <!-- Header -->
      <div class="p-6 border-b border-white/10">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-4">
            <.link
              navigate={~p"/workflows/#{@workflow_id}"}
              class="text-purple-400 hover:text-purple-300 transition-colors"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 19l-7-7m0 0l7-7m-7 7h18" />
              </svg>
            </.link>
            <div>
              <h1 class="text-2xl font-bold text-white">Grafo del Workflow</h1>
              <p class="text-slate-400 text-sm mt-1">
                <%= @workflow_id %>
                <%= if @workflow do %>
                  • <%= format_module(@workflow.workflow_module) %>
                <% end %>
              </p>
            </div>
          </div>

          <%= if @workflow do %>
            <div class="flex items-center gap-3">
              <button
                phx-click="export_svg"
                class="flex items-center gap-2 px-4 py-2 bg-purple-600/30 hover:bg-purple-600/50 border border-purple-500/30 rounded-lg text-purple-200 transition-colors"
                title="Exportar como SVG"
              >
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
                </svg>
                SVG
              </button>
              <.workflow_status_badge status={@workflow.status} />
            </div>
          <% end %>
        </div>
      </div>

      <!-- Graph Container -->
      <div class="p-6 flex gap-6">
        <!-- SVG Graph with Zoom/Pan -->
        <div
          id="graph-container"
          class="flex-1 bg-slate-800/50 backdrop-blur-sm rounded-2xl border border-white/10 overflow-hidden graph-container relative"
          phx-hook="GraphZoomPan"
        >
          <%= if @workflow do %>
            <div class="graph-viewport" id="graph-viewport" phx-hook="NodeStateTracker">
              <svg
                viewBox={"0 0 #{@svg_width} #{@svg_height}"}
                class="w-full h-auto min-h-[500px]"
                xmlns="http://www.w3.org/2000/svg"
              >
              <!-- Definitions for gradients and filters -->
              <defs>
                <!-- Glow filter for active node -->
                <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
                  <feGaussianBlur stdDeviation="4" result="coloredBlur"/>
                  <feMerge>
                    <feMergeNode in="coloredBlur"/>
                    <feMergeNode in="SourceGraphic"/>
                  </feMerge>
                </filter>

                <!-- Arrow marker -->
                <marker
                  id="arrowhead"
                  markerWidth="10"
                  markerHeight="7"
                  refX="9"
                  refY="3.5"
                  orient="auto"
                >
                  <polygon
                    points="0 0, 10 3.5, 0 7"
                    fill="#8b5cf6"
                  />
                </marker>

                <!-- Gradients for node states -->
                <linearGradient id="gradient-pending" x1="0%" y1="0%" x2="0%" y2="100%">
                  <stop offset="0%" style="stop-color:#475569"/>
                  <stop offset="100%" style="stop-color:#334155"/>
                </linearGradient>

                <linearGradient id="gradient-running" x1="0%" y1="0%" x2="0%" y2="100%">
                  <stop offset="0%" style="stop-color:#3b82f6"/>
                  <stop offset="100%" style="stop-color:#2563eb"/>
                </linearGradient>

                <linearGradient id="gradient-completed" x1="0%" y1="0%" x2="0%" y2="100%">
                  <stop offset="0%" style="stop-color:#22c55e"/>
                  <stop offset="100%" style="stop-color:#16a34a"/>
                </linearGradient>

                <linearGradient id="gradient-failed" x1="0%" y1="0%" x2="0%" y2="100%">
                  <stop offset="0%" style="stop-color:#ef4444"/>
                  <stop offset="100%" style="stop-color:#dc2626"/>
                </linearGradient>
              </defs>

              <!-- Connection lines -->
              <%= for edge <- @edges do %>
                <path
                  d={edge.path}
                  fill="none"
                  stroke={edge_stroke_color(edge)}
                  stroke-width="2"
                  stroke-dasharray={if edge.pending, do: "5,5", else: "none"}
                  marker-end="url(#arrowhead)"
                  class={"graph-edge #{edge_animation_class(edge)}"}
                />
              <% end %>

              <!-- Nodes -->
              <%= for node <- @nodes do %>
                <g
                  class="cursor-pointer group graph-node"
                  phx-click="select_node"
                  phx-value-node-id={node.id}
                  data-node-id={node.id}
                  data-node-state={node.state}
                >
                  <!-- SVG Tooltip -->
                  <title><%= node.tooltip %></title>

                  <!-- Node background -->
                  <rect
                    x={node.x}
                    y={node.y}
                    width={@node_width}
                    height={@node_height}
                    rx="12"
                    ry="12"
                    fill={"url(#gradient-#{node.state})"}
                    stroke={node_stroke_color(node.state)}
                    stroke-width={if node.state == :running, do: "3", else: "2"}
                    filter={if node.state == :running, do: "url(#glow)", else: "none"}
                    class={node_animation_class(node.state)}
                  />

                  <!-- Step icon -->
                  <text
                    x={node.x + 16}
                    y={node.y + 25}
                    fill="white"
                    font-size="18"
                    class="select-none"
                  >
                    <%= node_icon(node.state) %>
                  </text>

                  <!-- Step number -->
                  <text
                    x={node.x + 16}
                    y={node.y + 48}
                    fill="white"
                    font-size="12"
                    opacity="0.7"
                    class="select-none"
                  >
                    Step <%= node.index + 1 %>
                  </text>

                  <!-- Step name -->
                  <text
                    x={node.x + 45}
                    y={node.y + 36}
                    fill="white"
                    font-size="14"
                    font-weight="500"
                    class="select-none"
                  >
                    <%= truncate_name(node.label, 18) %>
                  </text>

                  <!-- Hover effect overlay -->
                  <rect
                    x={node.x}
                    y={node.y}
                    width={@node_width}
                    height={@node_height}
                    rx="12"
                    ry="12"
                    fill="white"
                    opacity="0"
                    class="group-hover:opacity-10 transition-opacity duration-200"
                  />
                </g>
              <% end %>
            </svg>
            </div>

            <!-- Zoom Controls -->
            <div class="zoom-controls">
              <button phx-click="zoom_in" class="zoom-btn" title="Acercar">+</button>
              <div class="zoom-level">100%</div>
              <button phx-click="zoom_out" class="zoom-btn" title="Alejar">−</button>
              <button phx-click="zoom_reset" class="zoom-btn text-sm" title="Restablecer">↺</button>
              <button phx-click="zoom_fit" class="zoom-btn text-xs" title="Ajustar">⊡</button>
            </div>
          <% else %>
            <div class="flex items-center justify-center h-96">
              <p class="text-slate-400">Workflow no encontrado</p>
            </div>
          <% end %>
        </div>

        <!-- Details Panel -->
        <%= if @show_details and @selected_node do %>
          <div class="w-80 bg-slate-800/50 backdrop-blur-sm rounded-2xl border border-white/10 p-6">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-lg font-semibold text-white">Detalles del Step</h3>
              <button
                phx-click="close_details"
                class="text-slate-400 hover:text-white transition-colors"
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </div>

            <div class="space-y-4">
              <div>
                <label class="text-xs text-slate-400 uppercase tracking-wider">Nombre</label>
                <p class="text-white font-medium mt-1"><%= @selected_node.label %></p>
              </div>

              <div>
                <label class="text-xs text-slate-400 uppercase tracking-wider">Módulo</label>
                <p class="text-slate-300 text-sm mt-1 font-mono break-all">
                  <%= @selected_node.module %>
                </p>
              </div>

              <div>
                <label class="text-xs text-slate-400 uppercase tracking-wider">Estado</label>
                <div class="mt-2">
                  <.node_state_badge state={@selected_node.state} />
                </div>
              </div>

              <div>
                <label class="text-xs text-slate-400 uppercase tracking-wider">Posición</label>
                <p class="text-slate-300 text-sm mt-1">
                  Step <%= @selected_node.index + 1 %> de <%= length(@nodes) %>
                </p>
              </div>

              <%= if @selected_node.state == :running do %>
                <div class="p-3 bg-blue-500/20 rounded-lg border border-blue-500/30">
                  <div class="flex items-center gap-2 text-blue-300">
                    <svg class="w-4 h-4 animate-spin" fill="none" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                    </svg>
                    <span class="text-sm">Ejecutando...</span>
                  </div>
                </div>
              <% end %>

              <%= if @selected_node.state == :failed and @workflow.error do %>
                <div class="p-3 bg-red-500/20 rounded-lg border border-red-500/30">
                  <label class="text-xs text-red-300 uppercase tracking-wider">Error</label>
                  <p class="text-red-200 text-sm mt-1 font-mono">
                    <%= inspect(@workflow.error) %>
                  </p>
                </div>
              <% end %>

              <!-- Historial de Intentos -->
              <%= if length(@step_attempts) > 0 do %>
                <div class="mt-4 pt-4 border-t border-white/10">
                  <label class="text-xs text-slate-400 uppercase tracking-wider">Historial de Intentos</label>
                  <p class="text-slate-500 text-xs mt-1 mb-3">
                    <%= length(@step_attempts) %> intento(s) registrado(s)
                  </p>
                  
                  <div class="space-y-2 max-h-48 overflow-y-auto custom-scrollbar">
                    <%= for {attempt, idx} <- Enum.with_index(@step_attempts, 1) do %>
                      <div class={[
                        "p-2 rounded-lg text-xs",
                        if(attempt.success, do: "bg-green-500/10 border border-green-500/20", else: "bg-red-500/10 border border-red-500/20")
                      ]}>
                        <div class="flex items-center justify-between mb-1">
                          <span class="font-medium text-white">
                            <%= if attempt.success do %>✅<% else %>❌<% end %>
                            Intento #<%= idx %>
                          </span>
                          <span class={if attempt.success, do: "text-green-400", else: "text-red-400"}>
                            <%= format_attempt_duration(attempt.duration_ms) %>
                          </span>
                        </div>
                        
                        <div class="text-slate-400">
                          <span><%= format_attempt_time(attempt.started_at) %></span>
                          <%= if attempt.ended_at do %>
                            <span class="mx-1">→</span>
                            <span><%= format_attempt_time(attempt.ended_at) %></span>
                          <% end %>
                        </div>
                        
                        <%= if attempt.error do %>
                          <div class="mt-1 text-red-300 font-mono text-xs truncate" title={inspect(attempt.error)}>
                            <%= truncate_attempt_error(attempt.error) %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% else %>
                <%= if @selected_node.timing != %{} do %>
                  <div class="mt-4 pt-4 border-t border-white/10">
                    <label class="text-xs text-slate-400 uppercase tracking-wider">Timing</label>
                    <div class="mt-2 text-sm text-slate-300 space-y-1">
                      <%= if @selected_node.timing[:started_at] do %>
                        <p>Inicio: <%= format_attempt_time(@selected_node.timing.started_at) %></p>
                      <% end %>
                      <%= if @selected_node.timing[:completed_at] do %>
                        <p>Fin: <%= format_attempt_time(@selected_node.timing.completed_at) %></p>
                      <% end %>
                      <%= if @selected_node.timing[:duration_ms] do %>
                        <p>Duración: <%= format_attempt_duration(@selected_node.timing.duration_ms) %></p>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <!-- Legend -->
      <div class="px-6 pb-6">
        <div class="bg-slate-800/30 backdrop-blur-sm rounded-xl border border-white/10 p-4">
          <div class="flex items-center gap-8 justify-center">
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 rounded bg-gradient-to-b from-slate-500 to-slate-600"></div>
              <span class="text-slate-400 text-sm">Pendiente</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 rounded bg-gradient-to-b from-blue-500 to-blue-600 animate-pulse"></div>
              <span class="text-slate-400 text-sm">Ejecutando</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 rounded bg-gradient-to-b from-green-500 to-green-600"></div>
              <span class="text-slate-400 text-sm">Completado</span>
            </div>
            <div class="flex items-center gap-2">
              <div class="w-4 h-4 rounded bg-gradient-to-b from-red-500 to-red-600"></div>
              <span class="text-slate-400 text-sm">Fallido</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Componentes
  # ============================================================================

  attr :status, :atom, required: true

  defp workflow_status_badge(assigns) do
    {text, class} =
      case assigns.status do
        :pending -> {"Pendiente", "bg-yellow-500/20 text-yellow-300 border-yellow-500/30"}
        :running -> {"Ejecutando", "bg-blue-500/20 text-blue-300 border-blue-500/30"}
        :completed -> {"Completado", "bg-green-500/20 text-green-300 border-green-500/30"}
        :failed -> {"Fallido", "bg-red-500/20 text-red-300 border-red-500/30"}
        _ -> {"Desconocido", "bg-slate-500/20 text-slate-300 border-slate-500/30"}
      end

    assigns = assign(assigns, text: text, class: class)

    ~H"""
    <span class={"px-4 py-2 rounded-full text-sm font-medium border #{@class}"}>
      <%= @text %>
    </span>
    """
  end

  attr :state, :atom, required: true

  defp node_state_badge(assigns) do
    {text, class} =
      case assigns.state do
        :pending -> {"⏳ Pendiente", "bg-slate-500/20 text-slate-300"}
        :running -> {"🔄 Ejecutando", "bg-blue-500/20 text-blue-300"}
        :completed -> {"✅ Completado", "bg-green-500/20 text-green-300"}
        :failed -> {"❌ Fallido", "bg-red-500/20 text-red-300"}
        _ -> {"❓ Desconocido", "bg-slate-500/20 text-slate-300"}
      end

    assigns = assign(assigns, text: text, class: class)

    ~H"""
    <span class={"px-3 py-1.5 rounded-lg text-sm #{@class}"}>
      <%= @text %>
    </span>
    """
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp load_workflow(socket, id) do
    workflow =
      case WorkflowActor.get_state(id) do
        {:ok, state} -> state
        {:error, :not_found} ->
          case WorkflowStore.get_workflow(id) do
            {:ok, record} -> record
            {:error, _} -> nil
          end
      end

    assign(socket, :workflow, workflow)
  end

  # Cargar todos los eventos para consultas posteriores
  defp load_all_events(socket, workflow_id) do
    events = case WorkflowStore.get_events(workflow_id) do
      {:ok, events} -> events
      {:error, _} -> []
    end
    assign(socket, :all_events, events)
  end

  # Procesar timings desde eventos ya cargados
  defp load_step_timings_from_events(socket) do
    events = socket.assigns[:all_events] || []

    timings = events
    |> Enum.reduce(%{}, fn event, acc ->
      step_index = event.metadata[:step_index]

      case {event.event_type, step_index} do
        {:step_started, idx} when is_integer(idx) ->
          Map.update(acc, idx, %{started_at: event.timestamp}, &Map.put(&1, :started_at, event.timestamp))

        {:step_completed, idx} when is_integer(idx) ->
          duration = event.metadata[:duration_ms] || 0
          Map.update(acc, idx, %{completed_at: event.timestamp, duration_ms: duration}, fn existing ->
            existing
            |> Map.put(:completed_at, event.timestamp)
            |> Map.put(:duration_ms, duration)
          end)

        {:step_failed, idx} when is_integer(idx) ->
          duration = event.metadata[:duration_ms] || 0
          error = event.metadata[:reason] || "Unknown error"
          Map.update(acc, idx, %{failed_at: event.timestamp, duration_ms: duration, error: error}, fn existing ->
            existing
            |> Map.put(:failed_at, event.timestamp)
            |> Map.put(:duration_ms, duration)
            |> Map.put(:error, error)
          end)

        _ -> acc
      end
    end)

    assign(socket, :step_timings, timings)
  end

  # Obtener intentos detallados desde todos los eventos
  defp get_step_attempts_from_events(all_events, step_index) when is_list(all_events) do
    # Filtrar eventos del step específico
    step_events = all_events
    |> Enum.filter(fn event ->
      event.metadata[:step_index] == step_index and
      event.event_type in [:step_started, :step_completed, :step_failed]
    end)
    |> Enum.sort_by(& &1.timestamp)

    # Reconstruir intentos emparejando started con completed/failed
    build_attempts_from_events(step_events, [])
  end
  defp get_step_attempts_from_events(_, _), do: []

  defp build_attempts_from_events([], attempts), do: Enum.reverse(attempts)
  defp build_attempts_from_events([%{event_type: :step_started} = start | rest], attempts) do
    # Buscar el siguiente completed o failed
    {end_event, remaining} = find_end_event(rest)
    
    attempt = %{
      started_at: start.timestamp,
      ended_at: end_event && end_event.timestamp,
      duration_ms: end_event && end_event.metadata[:duration_ms],
      success: end_event && end_event.event_type == :step_completed,
      error: end_event && end_event.metadata[:reason]
    }
    
    build_attempts_from_events(remaining, [attempt | attempts])
  end
  defp build_attempts_from_events([_ | rest], attempts) do
    # Ignorar eventos que no son step_started
    build_attempts_from_events(rest, attempts)
  end

  defp find_end_event([]), do: {nil, []}
  defp find_end_event([%{event_type: type} = event | rest]) when type in [:step_completed, :step_failed] do
    {event, rest}
  end
  defp find_end_event([_ | rest]), do: find_end_event(rest)

  # Formateo para intentos
  defp format_attempt_duration(nil), do: "-"
  defp format_attempt_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_attempt_duration(ms) when ms < 60_000 do
    seconds = Float.round(ms / 1000, 2)
    "#{seconds}s"
  end
  defp format_attempt_duration(ms) do
    minutes = div(ms, 60_000)
    seconds = Float.round(rem(ms, 60_000) / 1000, 1)
    "#{minutes}m #{seconds}s"
  end

  defp format_attempt_time(nil), do: "-"
  defp format_attempt_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
  defp format_attempt_time(timestamp) when is_binary(timestamp), do: timestamp
  defp format_attempt_time(_), do: "-"

  defp truncate_attempt_error(nil), do: nil
  defp truncate_attempt_error(error) when is_binary(error) do
    if String.length(error) > 40 do
      String.slice(error, 0, 37) <> "..."
    else
      error
    end
  end
  defp truncate_attempt_error(error), do: inspect(error) |> truncate_attempt_error()

  defp build_graph_data(socket) do
    case socket.assigns.workflow do
      nil ->
        assign(socket, nodes: [], edges: [], svg_width: 400, svg_height: 200)

      workflow ->
        # Obtener el grafo del workflow
        graph = get_workflow_graph(workflow.workflow_module)

        # Obtener timings para los nodos
        step_timings = socket.assigns[:step_timings] || %{}

        # Construir nodos con posiciones y timing
        nodes = build_nodes(graph, workflow, step_timings)

        # Construir edges
        edges = build_edges(graph, nodes)

        # Calcular dimensiones del SVG
        {svg_width, svg_height} = calculate_svg_dimensions(nodes)

        assign(socket,
          nodes: nodes,
          edges: edges,
          svg_width: svg_width,
          svg_height: svg_height,
          node_width: @node_width,
          node_height: @node_height
        )
    end
  end

  defp get_workflow_graph(workflow_module) do
    if function_exported?(workflow_module, :graph, 0) do
      workflow_module.graph()
    else
      # Fallback: construir grafo desde steps()
      steps = workflow_module.steps()
      Graph.from_linear_steps(steps)
    end
  end

  defp build_nodes(graph, workflow, step_timings) do
    current_step = workflow.current_step_index || 0
    status = workflow.status

    graph.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :step))
    |> Enum.sort_by(& &1.id)
    |> Enum.with_index()
    |> Enum.map(fn {node, index} ->
      state = calculate_node_state(index, current_step, status)
      timing = Map.get(step_timings, index, %{})

      # Calcular posición (layout horizontal)
      x = @padding + index * @node_spacing_x
      y = @padding

      # Construir tooltip con timing
      tooltip = build_tooltip(state, timing)

      %{
        id: node.id,
        index: index,
        label: format_step_label(node.module),
        module: format_module_full(node.module),
        state: state,
        x: x,
        y: y,
        timing: timing,
        tooltip: tooltip
      }
    end)
  end

  defp build_tooltip(state, timing) do
    lines = ["Estado: #{state_to_text(state)}"]

    lines = if timing[:started_at] do
      lines ++ ["Inicio: #{format_timestamp(timing.started_at)}"]
    else
      lines
    end

    lines = if timing[:completed_at] do
      lines ++ ["Fin: #{format_timestamp(timing.completed_at)}"]
    else
      if timing[:failed_at] do
        lines ++ ["Falló: #{format_timestamp(timing.failed_at)}"]
      else
        lines
      end
    end

    lines = if timing[:duration_ms] do
      lines ++ ["Duración: #{format_duration(timing.duration_ms)}"]
    else
      lines
    end

    lines = if timing[:error] do
      lines ++ ["Error: #{truncate_error(timing.error)}"]
    else
      lines
    end

    Enum.join(lines, "\n")
  end

  defp state_to_text(:pending), do: "Pendiente"
  defp state_to_text(:running), do: "Ejecutando"
  defp state_to_text(:completed), do: "Completado"
  defp state_to_text(:failed), do: "Fallido"
  defp state_to_text(_), do: "Desconocido"

  defp format_timestamp(nil), do: "-"
  defp format_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
  defp format_timestamp(_), do: "-"

  defp format_duration(nil), do: "-"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000 do
    seconds = ms / 1000
    :erlang.float_to_binary(seconds, decimals: 2) <> "s"
  end
  defp format_duration(ms) do
    minutes = div(ms, 60_000)
    seconds = rem(ms, 60_000) / 1000
    "#{minutes}m #{:erlang.float_to_binary(seconds, decimals: 1)}s"
  end

  defp truncate_error(error) when is_binary(error) do
    if String.length(error) > 30 do
      String.slice(error, 0, 27) <> "..."
    else
      error
    end
  end
  defp truncate_error(error), do: inspect(error) |> truncate_error()

  defp calculate_node_state(index, current_step, workflow_status) do
    cond do
      # Workflow completado: todos los steps están completos
      workflow_status == :completed -> :completed

      # Workflow fallido: el step actual es el que falló
      workflow_status == :failed and index == current_step -> :failed
      workflow_status == :failed and index < current_step -> :completed
      workflow_status == :failed and index > current_step -> :pending

      # Workflow running: el step actual está ejecutando
      workflow_status == :running and index == current_step -> :running
      workflow_status == :running and index < current_step -> :completed
      workflow_status == :running and index > current_step -> :pending

      # Workflow pending o cualquier otro estado
      index < current_step -> :completed
      index == current_step -> :pending
      true -> :pending
    end
  end

  defp build_edges(graph, nodes) do
    graph.edges
    |> Enum.flat_map(fn {from_id, targets} ->
      from_node = Enum.find(nodes, &(&1.id == from_id))

      targets
      |> Enum.map(fn
        {target_id, _condition} -> target_id
        target_id when is_binary(target_id) -> target_id
      end)
      |> Enum.map(fn target_id ->
        to_node = Enum.find(nodes, &(&1.id == target_id))

        if from_node && to_node do
          # Determine edge state based on connected nodes
          edge_state = determine_edge_state(from_node.state, to_node.state)

          %{
            from: from_id,
            to: target_id,
            path: calculate_edge_path(from_node, to_node),
            pending: edge_state == :pending,
            active: edge_state == :active,
            completed: edge_state == :completed
          }
        end
      end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  # Edge is completed when both nodes are completed
  defp determine_edge_state(:completed, :completed), do: :completed
  # Edge is active when from is completed/running and to is running
  defp determine_edge_state(:completed, :running), do: :active
  defp determine_edge_state(:running, :pending), do: :active
  # Otherwise pending
  defp determine_edge_state(_, _), do: :pending

  defp calculate_edge_path(from_node, to_node) do
    # Punto de salida: centro-derecha del nodo origen
    x1 = from_node.x + @node_width
    y1 = from_node.y + @node_height / 2

    # Punto de entrada: centro-izquierda del nodo destino
    x2 = to_node.x
    y2 = to_node.y + @node_height / 2

    # Si están en línea horizontal, dibujar línea recta
    if y1 == y2 do
      "M #{x1} #{y1} L #{x2} #{y2}"
    else
      # Curva bezier para conexiones no lineales
      cx1 = x1 + 40
      cx2 = x2 - 40
      "M #{x1} #{y1} C #{cx1} #{y1}, #{cx2} #{y2}, #{x2} #{y2}"
    end
  end

  defp calculate_svg_dimensions(nodes) do
    if nodes == [] do
      {400, 200}
    else
      max_x = nodes |> Enum.map(& &1.x) |> Enum.max()
      max_y = nodes |> Enum.map(& &1.y) |> Enum.max()

      width = max_x + @node_width + @padding * 2
      height = max_y + @node_height + @padding * 2

      {width, max(height, 200)}
    end
  end

  defp format_step_label(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
  end

  defp format_step_label(_), do: "Step"

  defp format_module_full(module) when is_atom(module) do
    module |> Module.split() |> Enum.join(".")
  end

  defp format_module_full(_), do: "Unknown"

  defp format_module(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.take(-2)
    |> Enum.join(".")
  end

  defp format_module(_), do: "Unknown"

  defp truncate_name(name, max_length) do
    if String.length(name) > max_length do
      String.slice(name, 0, max_length - 2) <> "…"
    else
      name
    end
  end

  defp node_stroke_color(:pending), do: "#64748b"
  defp node_stroke_color(:running), do: "#60a5fa"
  defp node_stroke_color(:completed), do: "#4ade80"
  defp node_stroke_color(:failed), do: "#f87171"
  defp node_stroke_color(_), do: "#64748b"

  defp node_icon(:pending), do: "⏳"
  defp node_icon(:running), do: "🔄"
  defp node_icon(:completed), do: "✅"
  defp node_icon(:failed), do: "❌"
  defp node_icon(_), do: "📦"

  # Animation classes for nodes
  defp node_animation_class(:running), do: "graph-node-running"
  defp node_animation_class(_), do: "transition-all duration-500"

  # Edge styling based on state
  defp edge_stroke_color(%{completed: true}), do: "#22c55e"
  defp edge_stroke_color(%{active: true}), do: "#3b82f6"
  defp edge_stroke_color(_), do: "#8b5cf6"

  defp edge_animation_class(%{active: true}), do: "graph-edge-active"
  defp edge_animation_class(%{completed: true}), do: "graph-edge-completed"
  defp edge_animation_class(_), do: ""
end
