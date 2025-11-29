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
        show_all_attempts: false,
        step_timings: %{},
        step_attempts: [],
        all_events: [],
        # Estado del modo de reproducción
        replay_mode: false,
        replay_playing: false,
        replay_speed: 1.0,
        replay_current_index: 0,
        replay_timeline: [],
        replay_state_at_index: nil,
        replay_timer_ref: nil
      )
      |> load_workflow(id)
      |> load_all_events(id)
      |> load_step_timings_from_events()
      |> build_graph_data()
      |> build_replay_timeline()

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
  def handle_info(:replay_tick, socket) do
    if socket.assigns.replay_playing do
      timeline = socket.assigns.replay_timeline
      current = socket.assigns.replay_current_index
      max_index = length(timeline) - 1

      if current < max_index do
        new_index = current + 1

        socket =
          socket
          |> assign(replay_current_index: new_index)
          |> apply_replay_state(new_index)
          |> schedule_next_tick()

        {:noreply, socket}
      else
        # Llegamos al final
        socket = stop_replay_timer(socket)
        {:noreply, assign(socket, replay_playing: false)}
      end
    else
      {:noreply, socket}
    end
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
    {:noreply, assign(socket, show_details: false, show_all_attempts: false)}
  end

  @impl true
  def handle_event("toggle_all_attempts", _params, socket) do
    {:noreply, assign(socket, :show_all_attempts, not socket.assigns.show_all_attempts)}
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

  # ============================================================================
  # Replay Mode Event Handlers
  # ============================================================================

  @impl true
  def handle_event("toggle_replay_mode", _params, socket) do
    if socket.assigns.replay_mode do
      # Salir del modo replay
      socket = stop_replay_timer(socket)
      socket =
        socket
        |> assign(
          replay_mode: false,
          replay_playing: false,
          replay_current_index: 0,
          replay_state_at_index: nil
        )
        |> build_graph_data()  # Restaurar estado real

      {:noreply, socket}
    else
      # Entrar al modo replay
      timeline = socket.assigns.replay_timeline

      if length(timeline) > 0 do
        socket =
          socket
          |> assign(
            replay_mode: true,
            replay_playing: false,
            replay_current_index: 0
          )
          |> apply_replay_state(0)

        {:noreply, socket}
      else
        {:noreply, put_flash(socket, :error, "No hay eventos para reproducir")}
      end
    end
  end

  @impl true
  def handle_event("replay_play_pause", _params, socket) do
    if socket.assigns.replay_playing do
      # Pausar
      socket = stop_replay_timer(socket)
      {:noreply, assign(socket, replay_playing: false)}
    else
      # Reproducir
      socket = start_replay_timer(socket)
      {:noreply, assign(socket, replay_playing: true)}
    end
  end

  @impl true
  def handle_event("replay_step_forward", _params, socket) do
    timeline = socket.assigns.replay_timeline
    current = socket.assigns.replay_current_index
    max_index = length(timeline) - 1

    if current < max_index do
      socket =
        socket
        |> assign(replay_current_index: current + 1)
        |> apply_replay_state(current + 1)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_step_back", _params, socket) do
    current = socket.assigns.replay_current_index

    if current > 0 do
      socket =
        socket
        |> assign(replay_current_index: current - 1)
        |> apply_replay_state(current - 1)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_go_start", _params, socket) do
    socket =
      socket
      |> stop_replay_timer()
      |> assign(replay_current_index: 0, replay_playing: false)
      |> apply_replay_state(0)

    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_go_end", _params, socket) do
    timeline = socket.assigns.replay_timeline
    max_index = max(0, length(timeline) - 1)

    socket =
      socket
      |> stop_replay_timer()
      |> assign(replay_current_index: max_index, replay_playing: false)
      |> apply_replay_state(max_index)

    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_seek", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    timeline = socket.assigns.replay_timeline
    max_index = length(timeline) - 1
    clamped_index = max(0, min(index, max_index))

    socket =
      socket
      |> assign(replay_current_index: clamped_index)
      |> apply_replay_state(clamped_index)

    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_set_speed", %{"speed" => speed_str}, socket) do
    speed = String.to_float(speed_str)

    socket =
      socket
      |> assign(replay_speed: speed)
      |> restart_replay_timer_if_playing()

    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_jump_to_event", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)

    socket =
      socket
      |> stop_replay_timer()
      |> assign(replay_current_index: index, replay_playing: false)
      |> apply_replay_state(index)

    {:noreply, socket}
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
              <!-- Replay Mode Toggle -->
              <button
                phx-click="toggle_replay_mode"
                class={"flex items-center gap-2 px-4 py-2 border rounded-lg transition-colors #{if @replay_mode, do: "bg-amber-600/50 border-amber-500/50 text-amber-200", else: "bg-purple-600/30 hover:bg-purple-600/50 border-purple-500/30 text-purple-200"}"}
                title={if @replay_mode, do: "Salir del modo reproducción", else: "Modo reproducción"}
              >
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <%= if @replay_mode do %>
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                  <% else %>
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                  <% end %>
                </svg>
                <%= if @replay_mode, do: "Salir", else: "Replay" %>
              </button>

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

        <!-- Replay Mode Banner -->
        <%= if @replay_mode do %>
          <div class="bg-amber-900/30 border-b border-amber-500/30 px-6 py-3">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <span class="text-amber-400 animate-pulse">🎬</span>
                <span class="text-amber-200 font-medium">Modo Reproducción</span>
                <span class="text-amber-400/70 text-sm">
                  Navegando por <%= length(@replay_timeline) %> eventos
                </span>
              </div>
              <div class="text-amber-300/70 text-sm">
                Evento <%= @replay_current_index + 1 %> de <%= length(@replay_timeline) %>
              </div>
            </div>
          </div>
        <% end %>
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
                  <div class="flex items-center justify-between mb-2">
                    <label class="text-xs text-slate-400 uppercase tracking-wider">Historial de Intentos</label>
                    <%= if length(@step_attempts) > 1 do %>
                      <.attempts_summary attempts={@step_attempts} />
                    <% end %>
                  </div>

                  <%= if length(@step_attempts) > 5 and not @show_all_attempts do %>
                    <!-- Resumen colapsado -->
                    <div class="mb-3">
                      <.retry_block_summary attempts={@step_attempts} />
                      <button
                        phx-click="toggle_all_attempts"
                        class="mt-2 w-full text-center text-xs text-purple-400 hover:text-purple-300 py-1 border border-purple-500/30 rounded-lg hover:bg-purple-500/10 transition-colors"
                      >
                        Ver los <%= length(@step_attempts) %> intentos detallados ↓
                      </button>
                    </div>
                  <% else %>
                    <!-- Lista detallada -->
                    <div class="space-y-2 max-h-64 overflow-y-auto custom-scrollbar">
                      <%= for {attempt, idx} <- Enum.with_index(@step_attempts, 1) do %>
                        <.attempt_card attempt={attempt} index={idx} />
                      <% end %>
                    </div>

                    <%= if length(@step_attempts) > 5 do %>
                      <button
                        phx-click="toggle_all_attempts"
                        class="mt-2 w-full text-center text-xs text-slate-400 hover:text-slate-300 py-1"
                      >
                        Colapsar ↑
                      </button>
                    <% end %>
                  <% end %>
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

      <!-- Replay Control Panel -->
      <%= if @replay_mode and length(@replay_timeline) > 0 do %>
        <.replay_control_panel
          timeline={@replay_timeline}
          current_index={@replay_current_index}
          playing={@replay_playing}
          speed={@replay_speed}
          replay_state={@replay_state_at_index}
        />
      <% end %>

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

  # Resumen de intentos (éxitos/fallos)
  attr :attempts, :list, required: true

  defp attempts_summary(assigns) do
    success_count = Enum.count(assigns.attempts, & &1.success)
    fail_count = length(assigns.attempts) - success_count

    assigns = assign(assigns, success_count: success_count, fail_count: fail_count)

    ~H"""
    <div class="flex items-center gap-2 text-xs">
      <%= if @success_count > 0 do %>
        <span class="text-green-400">✅ <%= @success_count %></span>
      <% end %>
      <%= if @fail_count > 0 do %>
        <span class="text-red-400">❌ <%= @fail_count %></span>
      <% end %>
    </div>
    """
  end

  # Bloque de resumen de reintentos (vista colapsada)
  attr :attempts, :list, required: true

  defp retry_block_summary(assigns) do
    attempts = assigns.attempts
    total_duration = attempts |> Enum.map(& &1.duration_ms || 0) |> Enum.sum()
    first_start = attempts |> List.first() |> Map.get(:started_at)
    last_end = attempts |> List.last() |> then(& &1.ended_at || &1.started_at)
    success_count = Enum.count(attempts, & &1.success)
    fail_count = length(attempts) - success_count

    assigns = assign(assigns,
      total_duration: total_duration,
      first_start: first_start,
      last_end: last_end,
      success_count: success_count,
      fail_count: fail_count,
      total: length(attempts)
    )

    ~H"""
    <div class="p-3 bg-slate-700/50 rounded-lg border border-slate-600/50 text-xs">
      <div class="flex items-center justify-between mb-2">
        <span class="text-white font-medium">🔄 <%= @total %> intentos</span>
        <span class="text-slate-300"><%= format_attempt_duration(@total_duration) %> total</span>
      </div>

      <!-- Barra de progreso visual -->
      <div class="h-2 bg-slate-600 rounded-full overflow-hidden flex mb-2">
        <%= if @fail_count > 0 do %>
          <div class="bg-red-500 h-full" style={"width: #{@fail_count / @total * 100}%"}></div>
        <% end %>
        <%= if @success_count > 0 do %>
          <div class="bg-green-500 h-full" style={"width: #{@success_count / @total * 100}%"}></div>
        <% end %>
      </div>

      <div class="flex justify-between text-slate-400">
        <span><%= format_attempt_time(@first_start) %></span>
        <span>→</span>
        <span><%= format_attempt_time(@last_end) %></span>
      </div>
    </div>
    """
  end

  # Card individual de intento
  attr :attempt, :map, required: true
  attr :index, :integer, required: true

  defp attempt_card(assigns) do
    ~H"""
    <div class={[
      "p-2 rounded-lg text-xs",
      if(@attempt.success, do: "bg-green-500/10 border border-green-500/20", else: "bg-red-500/10 border border-red-500/20")
    ]}>
      <div class="flex items-center justify-between mb-1">
        <span class="font-medium text-white">
          <%= if @attempt.success do %>✅<% else %>❌<% end %>
          Intento #<%= @index %>
        </span>
        <span class={if @attempt.success, do: "text-green-400", else: "text-red-400"}>
          <%= format_attempt_duration(@attempt.duration_ms) %>
        </span>
      </div>

      <div class="text-slate-400">
        <span><%= format_attempt_time(@attempt.started_at) %></span>
        <%= if @attempt.ended_at do %>
          <span class="mx-1">→</span>
          <span><%= format_attempt_time(@attempt.ended_at) %></span>
        <% end %>
      </div>

      <%= if @attempt.error do %>
        <div class="mt-1 text-red-300 font-mono text-xs truncate" title={inspect(@attempt.error)}>
          <%= truncate_attempt_error(@attempt.error) %>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Replay Control Panel Component
  # ============================================================================

  attr :timeline, :list, required: true
  attr :current_index, :integer, required: true
  attr :playing, :boolean, required: true
  attr :speed, :float, required: true
  attr :replay_state, :map, default: nil

  defp replay_control_panel(assigns) do
    timeline = assigns.timeline
    current = assigns.current_index
    max_index = max(0, length(timeline) - 1)
    progress = if max_index > 0, do: current / max_index * 100, else: 0

    current_event = Enum.at(timeline, current)

    # Encontrar marcadores (eventos importantes)
    markers = timeline
    |> Enum.filter(& &1.is_marker)
    |> Enum.map(& %{index: &1.index, severity: &1.severity, description: &1.description})

    assigns = assign(assigns,
      max_index: max_index,
      progress: progress,
      current_event: current_event,
      markers: markers,
      speeds: [0.25, 0.5, 1.0, 2.0, 4.0]
    )

    ~H"""
    <div class="px-6 pb-4">
      <div class="bg-slate-800/70 backdrop-blur-sm rounded-2xl border border-amber-500/30 p-4">
        <!-- Current Event Display -->
        <div class="mb-4 p-3 bg-slate-900/50 rounded-lg border border-slate-700/50">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <span class={[
                "w-3 h-3 rounded-full",
                event_severity_color(@current_event && @current_event.severity)
              ]}></span>
              <span class="text-white font-medium">
                <%= if @current_event, do: @current_event.description, else: "Sin evento" %>
              </span>
            </div>
            <span class="text-slate-400 text-sm">
              <%= if @current_event && @current_event.timestamp do %>
                <%= format_replay_timestamp(@current_event.timestamp) %>
              <% end %>
            </span>
          </div>
        </div>

        <!-- Timeline Scrubber -->
        <div class="mb-4">
          <div class="relative h-8 bg-slate-700/50 rounded-lg overflow-hidden">
            <!-- Progress bar -->
            <div
              class="absolute left-0 top-0 h-full bg-gradient-to-r from-amber-500/50 to-amber-400/50 transition-all duration-150"
              style={"width: #{@progress}%"}
            ></div>

            <!-- Markers -->
            <%= for marker <- @markers do %>
              <button
                phx-click="replay_jump_to_event"
                phx-value-index={marker.index}
                class={[
                  "absolute top-1 bottom-1 w-1.5 rounded-full z-10 hover:w-2 transition-all cursor-pointer",
                  marker_color(marker.severity)
                ]}
                style={"left: #{marker.index / max(@max_index, 1) * 100}%"}
                title={marker.description}
              ></button>
            <% end %>

            <!-- Clickable area for seeking -->
            <input
              type="range"
              min="0"
              max={@max_index}
              value={@current_index}
              phx-change="replay_seek"
              phx-value-index={@current_index}
              class="absolute inset-0 w-full h-full opacity-0 cursor-pointer"
            />

            <!-- Current position indicator -->
            <div
              class="absolute top-0 bottom-0 w-0.5 bg-white shadow-lg shadow-white/50"
              style={"left: #{@progress}%"}
            ></div>
          </div>

          <!-- Time labels -->
          <div class="flex justify-between text-xs text-slate-500 mt-1">
            <span>Inicio</span>
            <span>Evento <%= @current_index + 1 %> / <%= @max_index + 1 %></span>
            <span>Fin</span>
          </div>
        </div>

        <!-- Playback Controls -->
        <div class="flex items-center justify-center gap-4">
          <!-- Go to start -->
          <button
            phx-click="replay_go_start"
            class="p-2 text-slate-400 hover:text-white transition-colors"
            title="Ir al inicio"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 19l-7-7 7-7m8 14l-7-7 7-7" />
            </svg>
          </button>

          <!-- Step back -->
          <button
            phx-click="replay_step_back"
            class="p-2 text-slate-400 hover:text-white transition-colors disabled:opacity-50"
            disabled={@current_index == 0}
            title="Evento anterior"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
            </svg>
          </button>

          <!-- Play/Pause -->
          <button
            phx-click="replay_play_pause"
            class="p-4 bg-amber-500 hover:bg-amber-400 rounded-full text-slate-900 transition-colors"
            title={if @playing, do: "Pausar", else: "Reproducir"}
          >
            <%= if @playing do %>
              <svg class="w-6 h-6" fill="currentColor" viewBox="0 0 24 24">
                <path d="M6 4h4v16H6V4zm8 0h4v16h-4V4z" />
              </svg>
            <% else %>
              <svg class="w-6 h-6" fill="currentColor" viewBox="0 0 24 24">
                <path d="M8 5v14l11-7z" />
              </svg>
            <% end %>
          </button>

          <!-- Step forward -->
          <button
            phx-click="replay_step_forward"
            class="p-2 text-slate-400 hover:text-white transition-colors disabled:opacity-50"
            disabled={@current_index >= @max_index}
            title="Siguiente evento"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
            </svg>
          </button>

          <!-- Go to end -->
          <button
            phx-click="replay_go_end"
            class="p-2 text-slate-400 hover:text-white transition-colors"
            title="Ir al final"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 5l7 7-7 7M5 5l7 7-7 7" />
            </svg>
          </button>

          <!-- Speed selector -->
          <div class="ml-6 flex items-center gap-2">
            <span class="text-slate-500 text-sm">Velocidad:</span>
            <div class="flex gap-1">
              <%= for spd <- @speeds do %>
                <button
                  phx-click="replay_set_speed"
                  phx-value-speed={spd}
                  class={[
                    "px-2 py-1 text-xs rounded transition-colors",
                    if(@speed == spd,
                      do: "bg-amber-500 text-slate-900 font-medium",
                      else: "bg-slate-700 text-slate-300 hover:bg-slate-600"
                    )
                  ]}
                >
                  <%= spd %>x
                </button>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Event Timeline List (collapsible) -->
        <details class="mt-4">
          <summary class="cursor-pointer text-slate-400 hover:text-white text-sm flex items-center gap-2">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
            </svg>
            Ver todos los eventos (<%= length(@timeline) %>)
          </summary>

          <div class="mt-3 max-h-48 overflow-y-auto space-y-1">
            <%= for event <- @timeline do %>
              <button
                phx-click="replay_jump_to_event"
                phx-value-index={event.index}
                class={[
                  "w-full text-left p-2 rounded-lg text-sm flex items-center gap-3 transition-colors",
                  if(event.index == @current_index,
                    do: "bg-amber-500/20 border border-amber-500/30",
                    else: "hover:bg-slate-700/50"
                  )
                ]}
              >
                <span class={[
                  "w-2 h-2 rounded-full flex-shrink-0",
                  event_severity_color(event.severity)
                ]}></span>
                <span class={[
                  "flex-1 truncate",
                  if(event.index == @current_index, do: "text-white", else: "text-slate-300")
                ]}>
                  <%= event.description %>
                </span>
                <span class="text-slate-500 text-xs flex-shrink-0">
                  <%= format_replay_timestamp(event.timestamp) %>
                </span>
              </button>
            <% end %>
          </div>
        </details>
      </div>
    </div>
    """
  end

  defp event_severity_color(:error), do: "bg-red-500"
  defp event_severity_color(:warning), do: "bg-amber-500"
  defp event_severity_color(:success), do: "bg-green-500"
  defp event_severity_color(_), do: "bg-blue-500"

  defp marker_color(:error), do: "bg-red-500"
  defp marker_color(:warning), do: "bg-amber-500"
  defp marker_color(_), do: "bg-purple-500"

  defp format_replay_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S.") <> String.pad_leading("#{dt.microsecond |> elem(0) |> div(1000)}", 3, "0")
  end
  defp format_replay_timestamp(_), do: "--:--:--"

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
      event_data = Map.get(event, :data, %{}) || %{}
      step_index = event_data[:step_index]

      case {event.event_type, step_index} do
        {:step_started, idx} when is_integer(idx) ->
          Map.update(acc, idx, %{started_at: event.timestamp}, &Map.put(&1, :started_at, event.timestamp))

        {:step_completed, idx} when is_integer(idx) ->
          duration = event_data[:duration_ms] || 0
          Map.update(acc, idx, %{completed_at: event.timestamp, duration_ms: duration}, fn existing ->
            existing
            |> Map.put(:completed_at, event.timestamp)
            |> Map.put(:duration_ms, duration)
          end)

        {:step_failed, idx} when is_integer(idx) ->
          duration = event_data[:duration_ms] || 0
          error = event_data[:reason] || "Unknown error"
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
      event_data = Map.get(event, :data, %{}) || %{}
      event_data[:step_index] == step_index and
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

    end_event_data = if end_event, do: Map.get(end_event, :data, %{}) || %{}, else: %{}
    attempt = %{
      started_at: start.timestamp,
      ended_at: end_event && end_event.timestamp,
      duration_ms: end_event && end_event_data[:duration_ms],
      success: end_event && end_event.event_type == :step_completed,
      error: end_event && end_event_data[:reason]
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

        # Actualizar también el nodo seleccionado si existe
        updated_selected_node =
          if socket.assigns[:selected_node] do
            Enum.find(nodes, &(&1.id == socket.assigns.selected_node.id))
          else
            nil
          end

        assign(socket,
          nodes: nodes,
          edges: edges,
          svg_width: svg_width,
          svg_height: svg_height,
          node_width: @node_width,
          node_height: @node_height,
          selected_node: updated_selected_node
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

  defp format_step_label(module_string) when is_binary(module_string) do
    # Para strings como "Elixir.Beamflow.Domains.Insurance.Steps.ValidateIdentity"
    module_string
    |> String.split(".")
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

  # ============================================================================
  # Replay Mode Functions
  # ============================================================================

  @doc false
  defp build_replay_timeline(socket) do
    events = socket.assigns.all_events || []

    # Filtrar eventos relevantes para el replay y ordenar por timestamp
    timeline_events = events
    |> Enum.filter(fn event ->
      event.event_type in [
        :workflow_started,
        :step_started,
        :step_completed,
        :step_failed,
        :step_retry,
        :compensation_started,
        :compensation_completed,
        :compensation_failed,
        :workflow_completed,
        :workflow_failed
      ]
    end)
    |> Enum.sort_by(& &1.timestamp)
    |> Enum.with_index()
    |> Enum.map(fn {event, index} ->
      event_data = Map.get(event, :data, %{}) || %{}
      %{
        index: index,
        event: event,
        timestamp: event.timestamp,
        event_type: event.event_type,
        step_index: event_data[:step_index],
        description: describe_event(event),
        severity: event_severity(event.event_type),
        is_marker: is_marker_event?(event.event_type)
      }
    end)

    assign(socket, :replay_timeline, timeline_events)
  end

  defp describe_event(event) do
    event_data = Map.get(event, :data, %{}) || %{}
    step_info = cond do
      # Preferir el nombre del step si está disponible
      event_data[:step] ->
        step_name = event_data[:step] |> to_string() |> format_step_label()
        " - #{step_name}"

      # Fallback al módulo si está disponible
      event_data[:step_module] ->
        " - #{format_step_label(event_data[:step_module])}"

      # Último recurso: usar índice (1-based para humanos)
      event_data[:step_index] ->
        " - Step #{event_data[:step_index] + 1}"

      true ->
        ""
    end

    case event.event_type do
      :workflow_started -> "🚀 Workflow iniciado"
      :step_started -> "▶️ Step iniciado#{step_info}"
      :step_completed -> "✅ Step completado#{step_info}"
      :step_failed -> "❌ Step fallido#{step_info}"
      :step_retry -> "🔄 Retry#{step_info}"
      :compensation_started -> "⏪ Compensación iniciada#{step_info}"
      :compensation_completed -> "✅ Compensación completada#{step_info}"
      :compensation_failed -> "❌ Compensación fallida#{step_info}"
      :workflow_completed -> "🎉 Workflow completado"
      :workflow_failed -> "💥 Workflow fallido"
      _ -> "📋 #{event.event_type}"
    end
  end

  defp event_severity(:step_failed), do: :error
  defp event_severity(:compensation_failed), do: :error
  defp event_severity(:workflow_failed), do: :error
  defp event_severity(:step_retry), do: :warning
  defp event_severity(:compensation_started), do: :warning
  defp event_severity(:step_completed), do: :success
  defp event_severity(:compensation_completed), do: :success
  defp event_severity(:workflow_completed), do: :success
  defp event_severity(_), do: :info

  defp is_marker_event?(:step_failed), do: true
  defp is_marker_event?(:workflow_failed), do: true
  defp is_marker_event?(:step_retry), do: true
  defp is_marker_event?(:compensation_started), do: true
  defp is_marker_event?(_), do: false

  defp apply_replay_state(socket, index) do
    timeline = socket.assigns.replay_timeline

    if index >= 0 and index < length(timeline) do
      # Reconstruir el estado del workflow hasta este punto
      events_up_to_now = Enum.take(timeline, index + 1)
      replay_state = build_state_from_events(events_up_to_now, socket.assigns.workflow)

      socket
      |> assign(:replay_state_at_index, replay_state)
      |> rebuild_nodes_for_replay(replay_state)
    else
      socket
    end
  end

  defp build_state_from_events(timeline_events, _original_workflow) do
    # Empezar con estado inicial
    initial_state = %{
      status: :pending,
      current_step_index: 0,
      step_states: %{},  # %{step_index => :pending | :running | :completed | :failed}
      compensating: false,
      last_event: nil
    }

    Enum.reduce(timeline_events, initial_state, fn timeline_entry, state ->
      event = timeline_entry.event
      event_data = Map.get(event, :data, %{}) || %{}
      step_index = event_data[:step_index]

      case event.event_type do
        :workflow_started ->
          %{state | status: :running, last_event: timeline_entry}

        :step_started when is_integer(step_index) ->
          step_states = Map.put(state.step_states, step_index, :running)
          %{state | step_states: step_states, current_step_index: step_index, last_event: timeline_entry}

        :step_completed when is_integer(step_index) ->
          step_states = Map.put(state.step_states, step_index, :completed)
          %{state | step_states: step_states, current_step_index: step_index + 1, last_event: timeline_entry}

        :step_failed when is_integer(step_index) ->
          step_states = Map.put(state.step_states, step_index, :failed)
          %{state | step_states: step_states, current_step_index: step_index, last_event: timeline_entry}

        :step_retry when is_integer(step_index) ->
          step_states = Map.put(state.step_states, step_index, :running)
          %{state | step_states: step_states, last_event: timeline_entry}

        :compensation_started ->
          %{state | compensating: true, last_event: timeline_entry}

        :compensation_completed when is_integer(step_index) ->
          step_states = Map.put(state.step_states, step_index, :compensated)
          %{state | step_states: step_states, last_event: timeline_entry}

        :workflow_completed ->
          %{state | status: :completed, last_event: timeline_entry}

        :workflow_failed ->
          %{state | status: :failed, last_event: timeline_entry}

        _ ->
          %{state | last_event: timeline_entry}
      end
    end)
  end

  defp rebuild_nodes_for_replay(socket, replay_state) do
    # Reconstruir los nodos con el estado del replay
    workflow = socket.assigns.workflow

    if workflow do
      graph = get_workflow_graph(workflow.workflow_module)
      step_timings = socket.assigns[:step_timings] || %{}

      # Construir nodos con estados del replay
      nodes = graph.nodes
      |> Map.values()
      |> Enum.filter(&(&1.type == :step))
      |> Enum.sort_by(& &1.id)
      |> Enum.with_index()
      |> Enum.map(fn {node, index} ->
        # Obtener estado del replay o calcular basado en posición
        state = case Map.get(replay_state.step_states, index) do
          nil ->
            if index < replay_state.current_step_index, do: :completed, else: :pending
          :compensated -> :compensated
          s -> s
        end

        timing = Map.get(step_timings, index, %{})
        x = @padding + index * @node_spacing_x
        y = @padding
        tooltip = build_tooltip(state, timing)

        %{
          id: node.id,
          index: index,
          label: format_step_label(node.module),
          module: format_module_full(node.module),
          state: state,
          x: x,
          y: y,
          width: @node_width,
          height: @node_height,
          timing: timing,
          tooltip: tooltip
        }
      end)

      # Reconstruir edges
      edges = build_edges(graph, nodes)

      assign(socket, nodes: nodes, edges: edges)
    else
      socket
    end
  end

  defp start_replay_timer(socket) do
    # Calcular intervalo basado en velocidad (base 500ms por evento)
    interval = round(500 / socket.assigns.replay_speed)
    timer_ref = Process.send_after(self(), :replay_tick, interval)
    assign(socket, :replay_timer_ref, timer_ref)
  end

  defp stop_replay_timer(socket) do
    if socket.assigns.replay_timer_ref do
      Process.cancel_timer(socket.assigns.replay_timer_ref)
    end
    assign(socket, :replay_timer_ref, nil)
  end

  defp schedule_next_tick(socket) do
    interval = round(500 / socket.assigns.replay_speed)
    timer_ref = Process.send_after(self(), :replay_tick, interval)
    assign(socket, :replay_timer_ref, timer_ref)
  end

  defp restart_replay_timer_if_playing(socket) do
    if socket.assigns.replay_playing do
      socket
      |> stop_replay_timer()
      |> start_replay_timer()
    else
      socket
    end
  end
end
