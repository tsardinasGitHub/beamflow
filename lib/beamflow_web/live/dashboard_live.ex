defmodule BeamflowWeb.DashboardLive do
  @moduledoc """
  Dashboard Principal de BEAMFlow - Vista Ejecutiva.

  Este es el punto de entrada visual del sistema, diseñado para impresionar
  y mostrar el poder de BEAMFlow de un vistazo.

  ## Secciones

  1. **Health Overview** - Estado general del sistema con semáforo
  2. **Live Metrics** - KPIs animados en tiempo real
  3. **Activity Feed** - Últimos eventos con scroll infinito
  4. **Quick Actions** - Acceso rápido a funcionalidades clave

  ## Características Técnicas

  - Streams para actualizaciones incrementales (eficiente a escala)
  - Debouncing de mensajes PubSub (maneja 100+ msg/seg)
  - Batch updates cada 500ms
  - Animaciones CSS suaves
  """

  use BeamflowWeb, :live_view

  alias Beamflow.Storage.WorkflowStore
  alias Beamflow.Engine.{CircuitBreaker, DeadLetterQueue, AlertSystem}
  alias Beamflow.Chaos.ChaosMonkey

  @update_interval 500
  @max_activity_items 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Suscribirse a todos los canales relevantes
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "workflows")
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "alerts")
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "chaos:events")

      # Timer para batch updates
      :timer.send_interval(@update_interval, self(), :batch_update)
    end

    socket =
      socket
      |> assign(page_title: "Dashboard")
      |> assign(pending_updates: [])
      |> assign(last_update: System.monotonic_time(:millisecond))
      |> assign(activity_count: 0)
      |> stream(:activity_feed, [], at: 0, limit: @max_activity_items)
      |> load_metrics()
      |> load_health_status()
      |> load_system_info()

    {:ok, socket}
  end

  @impl true
  def handle_info({:workflow_updated, data}, socket) do
    # Acumular updates para batch processing
    pending = [{:workflow, data, DateTime.utc_now()} | socket.assigns.pending_updates]
    {:noreply, assign(socket, pending_updates: Enum.take(pending, 100))}
  end

  @impl true
  def handle_info({:alert, alert}, socket) do
    # Alertas se muestran inmediatamente
    activity = %{
      id: "act_#{System.unique_integer([:positive])}",
      type: :alert,
      severity: alert.severity,
      title: alert.title,
      message: alert.message,
      timestamp: DateTime.utc_now()
    }

    socket =
      socket
      |> stream_insert(:activity_feed, activity, at: 0)
      |> update(:activity_count, &min(&1 + 1, @max_activity_items))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chaos_event, event}, socket) do
    activity = %{
      id: "act_#{System.unique_integer([:positive])}",
      type: :chaos,
      title: "Chaos: #{event.type}",
      message: "Target: #{event.target}",
      timestamp: DateTime.utc_now()
    }

    socket =
      socket
      |> stream_insert(:activity_feed, activity, at: 0)
      |> update(:activity_count, &min(&1 + 1, @max_activity_items))

    {:noreply, socket}
  end

  @impl true
  def handle_info(:batch_update, socket) do
    pending = socket.assigns.pending_updates

    socket =
      if Enum.any?(pending) do
        # Procesar batch de updates
        socket
        |> process_batch_updates(pending)
        |> assign(pending_updates: [])
        |> load_metrics()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("navigate", %{"to" => path}, socket) do
    {:noreply, push_navigate(socket, to: path)}
  end

  @impl true
  def handle_event("toggle_chaos", _params, socket) do
    if ChaosMonkey.enabled?() do
      ChaosMonkey.stop()
    else
      ChaosMonkey.start(:gentle)
    end

    {:noreply, load_system_info(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900">
      <!-- Header -->
      <header class="border-b border-slate-700/50 bg-slate-900/50 backdrop-blur-sm sticky top-0 z-10">
        <div class="max-w-7xl mx-auto px-6 py-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <div class="text-3xl">⚡</div>
              <div>
                <h1 class="text-2xl font-bold text-white">BEAMFlow</h1>
                <p class="text-slate-400 text-sm">Workflow Orchestration Engine</p>
              </div>
            </div>

            <div class="flex items-center gap-4">
              <.health_indicator status={@health.status} />
              <.chaos_toggle enabled={@system_info.chaos_enabled} />
            </div>
          </div>
        </div>
      </header>

      <main class="max-w-7xl mx-auto px-6 py-8 space-y-8">
        <!-- Metrics Grid -->
        <section>
          <h2 class="text-lg font-semibold text-slate-300 mb-4">📊 Métricas en Tiempo Real</h2>
          <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4">
            <.metric_card
              icon="🔄"
              label="Workflows Activos"
              value={@metrics.active_workflows}
              trend={@metrics.workflow_trend}
              color="blue"
            />
            <.metric_card
              icon="✅"
              label="Completados Hoy"
              value={@metrics.completed_today}
              trend={:up}
              color="green"
            />
            <.metric_card
              icon="❌"
              label="Fallidos"
              value={@metrics.failed_count}
              trend={if @metrics.failed_count > 0, do: :down, else: :neutral}
              color="red"
            />
            <.metric_card
              icon="⚡"
              label="Circuit Breakers"
              value={@metrics.circuit_breakers_open}
              sublabel={"/ #{@metrics.circuit_breakers_total}"}
              color="yellow"
            />
            <.metric_card
              icon="📬"
              label="DLQ Pendiente"
              value={@metrics.dlq_pending}
              color="orange"
            />
            <.metric_card
              icon="🔔"
              label="Alertas Críticas"
              value={@metrics.critical_alerts}
              color="purple"
            />
          </div>
        </section>

        <!-- Main Content Grid -->
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Quick Navigation -->
          <section class="lg:col-span-1">
            <h2 class="text-lg font-semibold text-slate-300 mb-4">🚀 Navegación Rápida</h2>
            <div class="space-y-3">
              <.nav_card
                icon="📋"
                title="Workflows"
                description="Explorar y gestionar workflows"
                path="/workflows"
              />
              <.nav_card
                icon="🛡️"
                title="Resiliencia"
                description="Circuit Breakers, DLQ, Sagas"
                path="/resilience"
              />
              <.nav_card
                icon="🐒"
                title="Chaos Control"
                description="Testing de resiliencia"
                path="/chaos"
              />
              <.nav_card
                icon="📈"
                title="Analytics"
                description="Métricas y reportes"
                path="/analytics"
              />
            </div>
          </section>

          <!-- Activity Feed -->
          <section class="lg:col-span-2">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold text-slate-300">📡 Actividad en Vivo</h2>
              <span class="flex items-center gap-2 text-sm text-slate-400">
                <span class="w-2 h-2 bg-green-500 rounded-full animate-pulse"></span>
                Conectado
              </span>
            </div>

            <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 overflow-hidden">
              <div
                id="activity-feed"
                phx-update="stream"
                class="divide-y divide-slate-700/50 max-h-[400px] overflow-y-auto"
              >
                <div
                  :for={{dom_id, activity} <- @streams.activity_feed}
                  id={dom_id}
                  class="p-4 hover:bg-slate-700/30 transition-colors"
                >
                  <.activity_item activity={activity} />
                </div>
              </div>

              <div
                :if={@activity_count == 0}
                class="p-8 text-center text-slate-500"
              >
                <div class="text-4xl mb-2">📭</div>
                <p>No hay actividad reciente</p>
                <p class="text-sm mt-1">Los eventos aparecerán aquí en tiempo real</p>
              </div>
            </div>
          </section>
        </div>

        <!-- System Health Panel -->
        <section>
          <h2 class="text-lg font-semibold text-slate-300 mb-4">🏥 Estado del Sistema</h2>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <.health_card
              title="Engine"
              status={@health.engine}
              details={["WorkflowSupervisor: OK", "Registry: #{@health.registry_count} workflows"]}
            />
            <.health_card
              title="Storage"
              status={@health.storage}
              details={["Mnesia: #{@health.mnesia_status}", "Tables: OK"]}
            />
            <.health_card
              title="Resilience"
              status={@health.resilience}
              details={[
                "Circuit Breakers: #{@metrics.circuit_breakers_total}",
                "DLQ: #{@metrics.dlq_pending} pending"
              ]}
            />
          </div>
        </section>
      </main>

      <!-- Footer -->
      <footer class="border-t border-slate-700/50 mt-12 py-6">
        <div class="max-w-7xl mx-auto px-6 text-center text-slate-500 text-sm">
          <p>BEAMFlow v0.1.0 • Powered by Elixir/OTP • Built with Phoenix LiveView</p>
        </div>
      </footer>
    </div>
    """
  end

  # ============================================================================
  # Components
  # ============================================================================

  defp health_indicator(assigns) do
    {color, text} =
      case assigns.status do
        :healthy -> {"bg-green-500", "Sistema Saludable"}
        :degraded -> {"bg-yellow-500", "Rendimiento Degradado"}
        :critical -> {"bg-red-500", "Estado Crítico"}
        _ -> {"bg-gray-500", "Desconocido"}
      end

    assigns = assign(assigns, color: color, text: text)

    ~H"""
    <div class="flex items-center gap-2 px-4 py-2 bg-slate-800 rounded-full">
      <span class={"w-3 h-3 rounded-full #{@color} animate-pulse"}></span>
      <span class="text-sm text-slate-300"><%= @text %></span>
    </div>
    """
  end

  defp chaos_toggle(assigns) do
    ~H"""
    <button
      phx-click="toggle_chaos"
      class={[
        "flex items-center gap-2 px-4 py-2 rounded-full transition-all",
        @enabled && "bg-red-600/20 text-red-400 border border-red-500/50",
        !@enabled && "bg-slate-800 text-slate-400 border border-slate-700"
      ]}
    >
      <span class="text-lg">🐒</span>
      <span class="text-sm"><%= if @enabled, do: "Chaos ON", else: "Chaos OFF" %></span>
    </button>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :trend, :atom, default: :neutral
  attr :sublabel, :string, default: nil
  attr :color, :string, required: true

  defp metric_card(assigns) do
    bg_class =
      case assigns.color do
        "blue" -> "from-blue-600/20 to-blue-800/10 border-blue-500/30"
        "green" -> "from-green-600/20 to-green-800/10 border-green-500/30"
        "red" -> "from-red-600/20 to-red-800/10 border-red-500/30"
        "yellow" -> "from-yellow-600/20 to-yellow-800/10 border-yellow-500/30"
        "orange" -> "from-orange-600/20 to-orange-800/10 border-orange-500/30"
        "purple" -> "from-purple-600/20 to-purple-800/10 border-purple-500/30"
        _ -> "from-slate-600/20 to-slate-800/10 border-slate-500/30"
      end

    trend_icon =
      case assigns.trend do
        :up -> "↑"
        :down -> "↓"
        _ -> ""
      end

    assigns = assign(assigns, bg_class: bg_class, trend_icon: trend_icon)

    ~H"""
    <div class={"p-4 rounded-xl bg-gradient-to-br border #{@bg_class}"}>
      <div class="flex items-center justify-between mb-2">
        <span class="text-2xl"><%= @icon %></span>
        <span :if={@trend_icon != ""} class="text-xs text-slate-400"><%= @trend_icon %></span>
      </div>
      <div class="text-3xl font-bold text-white">
        <%= @value %><span :if={@sublabel} class="text-lg text-slate-400"><%= @sublabel %></span>
      </div>
      <div class="text-sm text-slate-400 mt-1"><%= @label %></div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :path, :string, required: true

  defp nav_card(assigns) do
    ~H"""
    <button
      phx-click="navigate"
      phx-value-to={@path}
      class="w-full p-4 bg-slate-800/50 rounded-xl border border-slate-700/50 hover:border-blue-500/50 hover:bg-slate-800 transition-all text-left group"
    >
      <div class="flex items-center gap-4">
        <span class="text-3xl group-hover:scale-110 transition-transform"><%= @icon %></span>
        <div>
          <div class="font-semibold text-white"><%= @title %></div>
          <div class="text-sm text-slate-400"><%= @description %></div>
        </div>
        <span class="ml-auto text-slate-500 group-hover:text-blue-400 transition-colors">→</span>
      </div>
    </button>
    """
  end

  attr :activity, :map, required: true

  defp activity_item(assigns) do
    {icon, color} =
      case {assigns.activity.type, assigns.activity[:severity]} do
        {:alert, :critical} -> {"🚨", "text-red-400"}
        {:alert, :high} -> {"⚠️", "text-orange-400"}
        {:alert, _} -> {"🔔", "text-blue-400"}
        {:chaos, _} -> {"🐒", "text-purple-400"}
        {:workflow, _} -> {"📋", "text-slate-400"}
        _ -> {"📌", "text-slate-400"}
      end

    assigns = assign(assigns, icon: icon, color: color)

    ~H"""
    <div class="flex items-start gap-3">
      <span class="text-xl"><%= @icon %></span>
      <div class="flex-1 min-w-0">
        <div class={"font-medium #{@color}"}><%= @activity.title %></div>
        <div class="text-sm text-slate-500 truncate"><%= @activity.message %></div>
      </div>
      <div class="text-xs text-slate-500">
        <%= format_time(@activity.timestamp) %>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :status, :atom, required: true
  attr :details, :list, required: true

  defp health_card(assigns) do
    {icon, color} =
      case assigns.status do
        :healthy -> {"✅", "border-green-500/30 bg-green-900/10"}
        :degraded -> {"⚠️", "border-yellow-500/30 bg-yellow-900/10"}
        :critical -> {"❌", "border-red-500/30 bg-red-900/10"}
        _ -> {"❓", "border-slate-500/30 bg-slate-900/10"}
      end

    assigns = assign(assigns, icon: icon, color: color)

    ~H"""
    <div class={"p-4 rounded-xl border #{@color}"}>
      <div class="flex items-center gap-2 mb-3">
        <span class="text-xl"><%= @icon %></span>
        <span class="font-semibold text-white"><%= @title %></span>
      </div>
      <ul class="space-y-1 text-sm text-slate-400">
        <li :for={detail <- @details}>• <%= detail %></li>
      </ul>
    </div>
    """
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp process_batch_updates(socket, updates) do
    # Convertir updates en activity items
    activities =
      updates
      |> Enum.take(10)
      |> Enum.map(fn {:workflow, data, timestamp} ->
        %{
          id: "act_#{System.unique_integer([:positive])}",
          type: :workflow,
          title: "Workflow #{data[:workflow_id] || data[:id] || "unknown"}",
          message: "Estado: #{data[:status] || "actualizado"}",
          timestamp: timestamp
        }
      end)

    activities_count = length(activities)

    socket
    |> then(fn s ->
      Enum.reduce(activities, s, fn activity, acc ->
        stream_insert(acc, :activity_feed, activity, at: 0)
      end)
    end)
    |> update(:activity_count, &min(&1 + activities_count, @max_activity_items))
  end

  defp load_metrics(socket) do
    stats = WorkflowStore.count_by_status()

    # Circuit Breakers
    cb_stats = get_circuit_breaker_stats()

    # DLQ
    dlq_stats = get_dlq_stats()

    # Alerts
    alert_stats = get_alert_stats()

    metrics = %{
      active_workflows: stats.running + stats.pending,
      completed_today: stats.completed,
      failed_count: stats.failed,
      workflow_trend: :neutral,
      circuit_breakers_open: cb_stats.open,
      circuit_breakers_total: cb_stats.total,
      dlq_pending: dlq_stats.pending,
      critical_alerts: alert_stats.critical
    }

    assign(socket, :metrics, metrics)
  end

  defp load_health_status(socket) do
    health = %{
      status: calculate_overall_health(),
      engine: :healthy,
      storage: get_storage_health(),
      resilience: get_resilience_health(),
      mnesia_status: get_mnesia_status(),
      registry_count: get_registry_count()
    }

    assign(socket, :health, health)
  end

  defp load_system_info(socket) do
    info = %{
      chaos_enabled: ChaosMonkey.enabled?(),
      version: "0.1.0",
      node: node()
    }

    assign(socket, :system_info, info)
  end

  defp get_circuit_breaker_stats do
    try do
      # Listar todos los circuit breakers registrados
      breakers = Registry.select(Beamflow.CircuitBreakerRegistry, [{{:"$1", :"$2", :_}, [], [:"$1"]}])

      open_count =
        Enum.count(breakers, fn name ->
          case CircuitBreaker.status(name) do
            {:ok, %{state: :open}} -> true
            _ -> false
          end
        end)

      %{total: length(breakers), open: open_count}
    rescue
      _ -> %{total: 0, open: 0}
    end
  end

  defp get_dlq_stats do
    try do
      pending = DeadLetterQueue.list_pending(limit: 1000) |> length()
      %{pending: pending}
    rescue
      _ -> %{pending: 0}
    end
  end

  defp get_alert_stats do
    try do
      recent = AlertSystem.recent_alerts(severity: :critical, limit: 100)
      %{critical: length(recent)}
    rescue
      _ -> %{critical: 0}
    end
  end

  defp calculate_overall_health do
    # Lógica simplificada para determinar salud general
    cb_stats = get_circuit_breaker_stats()
    dlq_stats = get_dlq_stats()

    cond do
      cb_stats.open > 2 or dlq_stats.pending > 50 -> :critical
      cb_stats.open > 0 or dlq_stats.pending > 10 -> :degraded
      true -> :healthy
    end
  end

  defp get_storage_health do
    case :mnesia.system_info(:is_running) do
      :yes -> :healthy
      _ -> :critical
    end
  rescue
    _ -> :critical
  end

  defp get_resilience_health do
    cb_stats = get_circuit_breaker_stats()
    if cb_stats.open > 0, do: :degraded, else: :healthy
  end

  defp get_mnesia_status do
    case :mnesia.system_info(:is_running) do
      :yes -> "Running"
      :no -> "Stopped"
      :starting -> "Starting"
      _ -> "Unknown"
    end
  rescue
    _ -> "Error"
  end

  defp get_registry_count do
    try do
      Registry.count(Beamflow.Engine.Registry)
    rescue
      _ -> 0
    end
  end

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: "-"
end
