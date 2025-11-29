defmodule BeamflowWeb.ResilienceLive do
  @moduledoc """
  Panel de Resiliencia - Monitoreo de Circuit Breakers, DLQ y Sagas.

  Este panel proporciona visibilidad completa sobre los mecanismos
  de resiliencia del sistema.

  ## Secciones

  1. **Circuit Breakers** - Estado visual de cada breaker
  2. **Dead Letter Queue** - Cola de workflows fallidos
  3. **Saga Compensations** - Historial de compensaciones
  """

  use BeamflowWeb, :live_view

  alias Beamflow.Engine.{CircuitBreaker, DeadLetterQueue, AlertSystem}

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "alerts")
    end

    socket =
      socket
      |> assign(page_title: "Resiliencia")
      |> assign(active_tab: :circuit_breakers)
      |> assign(selected_dlq_entry: nil)
      |> load_circuit_breakers()
      |> load_dlq_entries()
      |> load_recent_alerts()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      socket
      |> load_circuit_breakers()
      |> load_dlq_entries()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:alert, _alert}, socket) do
    {:noreply, load_recent_alerts(socket)}
  end

  @impl true
  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("reset_circuit_breaker", %{"name" => name}, socket) do
    name_atom = String.to_existing_atom(name)

    case CircuitBreaker.reset(name_atom) do
      :ok ->
        socket =
          socket
          |> put_flash_auto_hide(:info, "Circuit breaker #{name} reseteado")
          |> load_circuit_breakers()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash_auto_hide(socket, :error, "Error: #{inspect(reason)}", 5_000)}
    end
  end

  @impl true
  def handle_event("retry_dlq_entry", %{"id" => id}, socket) do
    case DeadLetterQueue.retry(id) do
      {:ok, _} ->
        socket =
          socket
          |> put_flash_auto_hide(:info, "Reintento programado para #{id}")
          |> load_dlq_entries()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash_auto_hide(socket, :error, "Error: #{inspect(reason)}", 5_000)}
    end
  end

  @impl true
  def handle_event("resolve_dlq_entry", %{"id" => id, "resolution" => resolution}, socket) do
    resolution_atom = String.to_existing_atom(resolution)

    case DeadLetterQueue.resolve(id, resolution_atom, "Manual resolution from UI") do
      {:ok, _} ->
        socket =
          socket
          |> put_flash_auto_hide(:info, "Entrada #{id} marcada como #{resolution}")
          |> load_dlq_entries()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash_auto_hide(socket, :error, "Error: #{inspect(reason)}", 5_000)}
    end
  end

  @impl true
  def handle_event("select_dlq_entry", %{"id" => id}, socket) do
    entry = Enum.find(socket.assigns.dlq_entries, &(&1.id == id))
    {:noreply, assign(socket, selected_dlq_entry: entry)}
  end

  @impl true
  def handle_event("close_dlq_detail", _params, socket) do
    {:noreply, assign(socket, selected_dlq_entry: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-900">
      <!-- Header -->
      <header class="bg-slate-800/50 border-b border-slate-700/50 sticky top-0 z-10 backdrop-blur-sm">
        <div class="max-w-7xl mx-auto px-6 py-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <.link navigate="/" class="text-slate-400 hover:text-white transition">
                ← Dashboard
              </.link>
              <h1 class="text-xl font-bold text-white">🛡️ Panel de Resiliencia</h1>
            </div>

            <div class="flex items-center gap-2 text-sm text-slate-400">
              <span class="w-2 h-2 bg-green-500 rounded-full animate-pulse"></span>
              Auto-refresh cada 2s
            </div>
          </div>
        </div>
      </header>

      <main class="max-w-7xl mx-auto px-6 py-6">
        <!-- Tabs -->
        <div class="flex gap-2 mb-6">
          <.tab_button
            label="Circuit Breakers"
            icon="⚡"
            tab={:circuit_breakers}
            active={@active_tab}
            count={length(@circuit_breakers)}
          />
          <.tab_button
            label="Dead Letter Queue"
            icon="📬"
            tab={:dlq}
            active={@active_tab}
            count={length(@dlq_entries)}
          />
          <.tab_button
            label="Alertas Recientes"
            icon="🔔"
            tab={:alerts}
            active={@active_tab}
            count={length(@recent_alerts)}
          />
        </div>

        <!-- Tab Content -->
        <div class="space-y-6">
          <!-- Circuit Breakers Tab -->
          <section :if={@active_tab == :circuit_breakers} class="space-y-4">
            <div :if={@circuit_breakers == []} class="text-center py-12 text-slate-500">
              <div class="text-5xl mb-4">⚡</div>
              <p class="text-lg">No hay Circuit Breakers registrados</p>
              <p class="text-sm mt-2">Los breakers aparecerán cuando se usen servicios externos</p>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              <.circuit_breaker_card :for={cb <- @circuit_breakers} breaker={cb} />
            </div>
          </section>

          <!-- DLQ Tab -->
          <section :if={@active_tab == :dlq} class="space-y-4">
            <div :if={@dlq_entries == []} class="text-center py-12 text-slate-500">
              <div class="text-5xl mb-4">✨</div>
              <p class="text-lg">Dead Letter Queue vacía</p>
              <p class="text-sm mt-2">No hay workflows fallidos pendientes de revisión</p>
            </div>

            <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
              <.dlq_entry_card :for={entry <- @dlq_entries} entry={entry} />
            </div>

            <!-- DLQ Detail Modal -->
            <.dlq_detail_modal :if={@selected_dlq_entry} entry={@selected_dlq_entry} />
          </section>

          <!-- Alerts Tab -->
          <section :if={@active_tab == :alerts}>
            <div :if={@recent_alerts == []} class="text-center py-12 text-slate-500">
              <div class="text-5xl mb-4">🔕</div>
              <p class="text-lg">No hay alertas recientes</p>
            </div>

            <div class="space-y-3">
              <.alert_card :for={alert <- @recent_alerts} alert={alert} />
            </div>
          </section>
        </div>
      </main>
    </div>
    """
  end

  # ============================================================================
  # Components
  # ============================================================================

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :tab, :atom, required: true
  attr :active, :atom, required: true
  attr :count, :integer, default: 0

  defp tab_button(assigns) do
    ~H"""
    <button
      phx-click="change_tab"
      phx-value-tab={@tab}
      class={[
        "px-4 py-2 rounded-lg flex items-center gap-2 transition",
        @tab == @active && "bg-blue-600 text-white",
        @tab != @active && "bg-slate-800 text-slate-400 hover:bg-slate-700 hover:text-white"
      ]}
    >
      <span><%= @icon %></span>
      <span><%= @label %></span>
      <span :if={@count > 0} class={[
        "px-2 py-0.5 text-xs rounded-full",
        @tab == @active && "bg-blue-500",
        @tab != @active && "bg-slate-700"
      ]}>
        <%= @count %>
      </span>
    </button>
    """
  end

  attr :breaker, :map, required: true

  defp circuit_breaker_card(assigns) do
    {state_icon, state_color, state_bg} =
      case assigns.breaker.state do
        :closed -> {"✅", "text-green-400", "border-green-500/30 bg-green-900/10"}
        :open -> {"🔴", "text-red-400", "border-red-500/30 bg-red-900/10"}
        :half_open -> {"🟡", "text-yellow-400", "border-yellow-500/30 bg-yellow-900/10"}
        _ -> {"❓", "text-slate-400", "border-slate-500/30 bg-slate-900/10"}
      end

    assigns = assign(assigns,
      state_icon: state_icon,
      state_color: state_color,
      state_bg: state_bg
    )

    ~H"""
    <div class={"p-4 rounded-xl border #{@state_bg}"}>
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <span class="text-xl"><%= @state_icon %></span>
          <span class="font-semibold text-white"><%= @breaker.name %></span>
        </div>
        <span class={"text-sm font-medium #{@state_color}"}>
          <%= String.upcase(to_string(@breaker.state)) %>
        </span>
      </div>

      <div class="grid grid-cols-2 gap-2 text-sm mb-4">
        <div class="text-slate-400">
          Fallos: <span class="text-white"><%= @breaker.failure_count %></span>
        </div>
        <div class="text-slate-400">
          Éxitos: <span class="text-white"><%= @breaker.success_count %></span>
        </div>
        <div class="text-slate-400">
          Threshold: <span class="text-white"><%= @breaker.failure_threshold %></span>
        </div>
        <div class="text-slate-400">
          Timeout: <span class="text-white"><%= @breaker.recovery_timeout %>ms</span>
        </div>
      </div>

      <div :if={@breaker.state != :closed} class="flex justify-end">
        <button
          phx-click="reset_circuit_breaker"
          phx-value-name={@breaker.name}
          class="px-3 py-1 bg-slate-700 text-slate-300 rounded hover:bg-slate-600 transition text-sm"
        >
          Reset
        </button>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp dlq_entry_card(assigns) do
    severity_color =
      case assigns.entry.type do
        :critical_failure -> "border-red-500/50 bg-red-900/20"
        :compensation_failed -> "border-orange-500/50 bg-orange-900/20"
        _ -> "border-slate-700/50 bg-slate-800/50"
      end

    assigns = assign(assigns, severity_color: severity_color)

    ~H"""
    <div class={"p-4 rounded-xl border #{@severity_color}"}>
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          <span class="text-lg"><%= type_icon(@entry.type) %></span>
          <span class="font-mono text-sm text-blue-400"><%= @entry.workflow_id %></span>
        </div>
        <span class="text-xs text-slate-500"><%= format_relative_time(@entry.created_at) %></span>
      </div>

      <div class="text-sm text-slate-400 mb-3">
        <span class="font-medium text-white"><%= format_type(@entry.type) %></span>
        <span :if={@entry.failed_step}> en step: <%= @entry.failed_step %></span>
      </div>

      <div class="text-xs text-red-400 bg-red-900/20 p-2 rounded mb-3 font-mono truncate">
        <%= inspect(@entry.error) %>
      </div>

      <div class="flex items-center gap-2">
        <button
          phx-click="select_dlq_entry"
          phx-value-id={@entry.id}
          class="px-3 py-1 bg-slate-700 text-slate-300 rounded hover:bg-slate-600 transition text-sm"
        >
          Ver detalles
        </button>
        <button
          phx-click="retry_dlq_entry"
          phx-value-id={@entry.id}
          class="px-3 py-1 bg-blue-600 text-white rounded hover:bg-blue-700 transition text-sm"
        >
          Reintentar
        </button>
        <button
          phx-click="resolve_dlq_entry"
          phx-value-id={@entry.id}
          phx-value-resolution="resolved"
          class="px-3 py-1 bg-green-600 text-white rounded hover:bg-green-700 transition text-sm"
        >
          Resolver
        </button>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp dlq_detail_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div class="bg-slate-800 rounded-xl border border-slate-700 w-full max-w-2xl max-h-[80vh] overflow-hidden">
        <div class="flex items-center justify-between p-4 border-b border-slate-700">
          <h3 class="font-semibold text-white">Detalles: <%= @entry.id %></h3>
          <button
            phx-click="close_dlq_detail"
            class="text-slate-400 hover:text-white transition"
          >
            ✕
          </button>
        </div>

        <div class="p-4 space-y-4 overflow-y-auto max-h-[60vh]">
          <div class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <span class="text-slate-400">Workflow ID:</span>
              <div class="text-white font-mono"><%= @entry.workflow_id %></div>
            </div>
            <div>
              <span class="text-slate-400">Tipo:</span>
              <div class="text-white"><%= format_type(@entry.type) %></div>
            </div>
            <div>
              <span class="text-slate-400">Estado:</span>
              <div class="text-white"><%= @entry.status %></div>
            </div>
            <div>
              <span class="text-slate-400">Reintentos:</span>
              <div class="text-white"><%= @entry.retry_count %></div>
            </div>
            <div>
              <span class="text-slate-400">Creado:</span>
              <div class="text-white"><%= format_datetime(@entry.created_at) %></div>
            </div>
            <div>
              <span class="text-slate-400">Actualizado:</span>
              <div class="text-white"><%= format_datetime(@entry.updated_at) %></div>
            </div>
          </div>

          <div>
            <span class="text-slate-400 text-sm">Error:</span>
            <pre class="mt-1 p-3 bg-slate-900 rounded text-red-400 text-xs overflow-x-auto"><%= inspect(@entry.error, pretty: true) %></pre>
          </div>

          <div>
            <span class="text-slate-400 text-sm">Contexto (sanitizado):</span>
            <pre class="mt-1 p-3 bg-slate-900 rounded text-slate-300 text-xs overflow-x-auto"><%= inspect(@entry.context, pretty: true, limit: 50) %></pre>
          </div>
        </div>

        <div class="flex items-center justify-end gap-2 p-4 border-t border-slate-700">
          <button
            phx-click="retry_dlq_entry"
            phx-value-id={@entry.id}
            class="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition"
          >
            Reintentar
          </button>
          <button
            phx-click="resolve_dlq_entry"
            phx-value-id={@entry.id}
            phx-value-resolution="abandoned"
            class="px-4 py-2 bg-slate-700 text-slate-300 rounded-lg hover:bg-slate-600 transition"
          >
            Abandonar
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :alert, :map, required: true

  defp alert_card(assigns) do
    {icon, color} =
      case assigns.alert.severity do
        :critical -> {"🚨", "border-red-500/50 bg-red-900/20"}
        :high -> {"⚠️", "border-orange-500/50 bg-orange-900/20"}
        :medium -> {"🔔", "border-yellow-500/50 bg-yellow-900/20"}
        _ -> {"ℹ️", "border-blue-500/50 bg-blue-900/20"}
      end

    assigns = assign(assigns, icon: icon, color: color)

    ~H"""
    <div class={"p-4 rounded-xl border #{@color} flex items-start gap-3"}>
      <span class="text-xl"><%= @icon %></span>
      <div class="flex-1">
        <div class="flex items-center justify-between">
          <span class="font-medium text-white"><%= @alert.title %></span>
          <span class="text-xs text-slate-500"><%= format_relative_time(@alert.timestamp) %></span>
        </div>
        <p class="text-sm text-slate-400 mt-1"><%= @alert.message %></p>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_circuit_breakers(socket) do
    breakers =
      try do
        Registry.select(Beamflow.CircuitBreakerRegistry, [{{:"$1", :"$2", :_}, [], [:"$1"]}])
        |> Enum.map(fn name ->
          case CircuitBreaker.status(name) do
            {:ok, status} -> Map.put(status, :name, name)
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      rescue
        _ -> []
      end

    assign(socket, circuit_breakers: breakers)
  end

  defp load_dlq_entries(socket) do
    entries =
      try do
        case DeadLetterQueue.list_pending(limit: 50) do
          {:ok, list} -> list
          _ -> []
        end
      rescue
        _ -> []
      end

    assign(socket, dlq_entries: entries)
  end

  defp load_recent_alerts(socket) do
    alerts =
      try do
        AlertSystem.recent_alerts(limit: 20)
      rescue
        _ -> []
      end

    assign(socket, recent_alerts: alerts)
  end

  defp type_icon(:critical_failure), do: "💀"
  defp type_icon(:compensation_failed), do: "🔄"
  defp type_icon(:workflow_failed), do: "❌"
  defp type_icon(_), do: "📋"

  defp format_type(:critical_failure), do: "Fallo Crítico"
  defp format_type(:compensation_failed), do: "Compensación Fallida"
  defp format_type(:workflow_failed), do: "Workflow Fallido"
  defp format_type(type), do: to_string(type)

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
  defp format_datetime(_), do: "-"

  defp format_relative_time(nil), do: "-"
  defp format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "hace #{diff}s"
      diff < 3600 -> "hace #{div(diff, 60)}m"
      diff < 86400 -> "hace #{div(diff, 3600)}h"
      true -> "hace #{div(diff, 86400)}d"
    end
  end
  defp format_relative_time(_), do: "-"
end
