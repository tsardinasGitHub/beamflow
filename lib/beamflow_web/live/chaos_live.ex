defmodule BeamflowWeb.ChaosLive do
  @moduledoc """
  Chaos Control Center - Interfaz para Chaos Engineering.

  Este panel permite:
  - Activar/desactivar ChaosMonkey
  - Seleccionar perfiles de chaos
  - Inyectar fallos manualmente
  - Ver métricas de recovery en tiempo real
  - Validar idempotencia de steps
  """

  use BeamflowWeb, :live_view

  alias Beamflow.Chaos.{ChaosMonkey, IdempotencyValidator}

  @refresh_interval 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "chaos:events")
      :timer.send_interval(@refresh_interval, self(), :refresh_stats)
    end

    socket =
      socket
      |> assign(page_title: "Chaos Control")
      |> assign(event_count: 0)
      |> stream(:chaos_events, [], at: 0, limit: 50)
      |> load_chaos_state()
      |> load_idempotency_report()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    {:noreply, load_chaos_state(socket)}
  end

  @impl true
  def handle_info({:chaos_event, event}, socket) do
    formatted_event = %{
      id: event.id,
      type: event.type,
      target: event.target,
      timestamp: event.timestamp
    }

    socket =
      socket
      |> stream_insert(:chaos_events, formatted_event, at: 0)
      |> update(:event_count, &min(&1 + 1, 50))

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_chaos", _params, socket) do
    if socket.assigns.chaos_enabled do
      ChaosMonkey.stop()
    else
      ChaosMonkey.start(socket.assigns.current_profile)
    end

    {:noreply, load_chaos_state(socket)}
  end

  @impl true
  def handle_event("set_profile", %{"profile" => profile}, socket) do
    profile_atom = String.to_existing_atom(profile)
    ChaosMonkey.set_profile(profile_atom)

    socket =
      socket
      |> assign(current_profile: profile_atom)
      |> load_chaos_state()

    {:noreply, socket}
  end

  @impl true
  def handle_event("inject_fault", %{"type" => type}, socket) do
    type_atom = String.to_existing_atom(type)

    case ChaosMonkey.inject(type_atom, target: :random_workflow) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Fallo #{type} inyectado")}

      {:error, :chaos_not_enabled} ->
        {:noreply, put_flash(socket, :error, "ChaosMonkey no está activo")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reset_stats", _params, socket) do
    ChaosMonkey.reset_stats()
    IdempotencyValidator.reset()

    socket =
      socket
      |> put_flash(:info, "Estadísticas reseteadas")
      |> load_chaos_state()
      |> load_idempotency_report()

    {:noreply, socket}
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
              <h1 class="text-xl font-bold text-white">🐒 Chaos Control Center</h1>
            </div>

            <.chaos_toggle enabled={@chaos_enabled} />
          </div>
        </div>
      </header>

      <main class="max-w-7xl mx-auto px-6 py-6 space-y-6">
        <!-- Warning Banner -->
        <div class="bg-yellow-900/30 border border-yellow-500/50 rounded-xl p-4 flex items-start gap-3">
          <span class="text-2xl">⚠️</span>
          <div>
            <div class="font-semibold text-yellow-400">Entorno de Testing</div>
            <p class="text-yellow-300/80 text-sm">
              ChaosMonkey inyecta fallos aleatorios para probar la resiliencia del sistema.
              Solo usar en desarrollo/testing.
            </p>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Control Panel -->
          <section class="lg:col-span-1 space-y-6">
            <!-- Profile Selector -->
            <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-4">
              <h3 class="font-semibold text-white mb-4">🎚️ Perfil de Chaos</h3>

              <div class="space-y-2">
                <.profile_button
                  profile={:gentle}
                  current={@current_profile}
                  label="Gentle"
                  description="5% crash, 8% error"
                  color="green"
                />
                <.profile_button
                  profile={:moderate}
                  current={@current_profile}
                  label="Moderate"
                  description="15% crash, 20% error"
                  color="yellow"
                />
                <.profile_button
                  profile={:aggressive}
                  current={@current_profile}
                  label="Aggressive"
                  description="30% crash, 35% error"
                  color="red"
                />
              </div>
            </div>

            <!-- Manual Injection -->
            <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-4">
              <h3 class="font-semibold text-white mb-4">💉 Inyección Manual</h3>

              <div class="grid grid-cols-2 gap-2">
                <.inject_button type={:crash} icon="💥" label="Crash" enabled={@chaos_enabled} />
                <.inject_button type={:timeout} icon="⏰" label="Timeout" enabled={@chaos_enabled} />
                <.inject_button type={:error} icon="❌" label="Error" enabled={@chaos_enabled} />
                <.inject_button type={:latency} icon="🐢" label="Latency" enabled={@chaos_enabled} />
                <.inject_button
                  type={:compensation_fail}
                  icon="🔄"
                  label="Comp Fail"
                  enabled={@chaos_enabled}
                  class="col-span-2"
                />
              </div>
            </div>

            <!-- Actions -->
            <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-4">
              <h3 class="font-semibold text-white mb-4">⚙️ Acciones</h3>

              <button
                phx-click="reset_stats"
                class="w-full px-4 py-2 bg-slate-700 text-slate-300 rounded-lg hover:bg-slate-600 transition"
              >
                🔄 Resetear Estadísticas
              </button>
            </div>
          </section>

          <!-- Stats & Events -->
          <section class="lg:col-span-2 space-y-6">
            <!-- Stats Grid -->
            <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
              <.stat_card
                icon="💉"
                label="Inyecciones"
                value={@stats.total_injections}
                color="blue"
              />
              <.stat_card icon="💥" label="Crashes" value={@stats.crashes} color="red" />
              <.stat_card icon="✅" label="Recoveries" value={@stats.successful_recoveries} color="green" />
              <.stat_card
                icon="❌"
                label="Failed Rec."
                value={@stats.failed_recoveries}
                color="orange"
              />
            </div>

            <!-- Recovery Rate -->
            <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-4">
              <div class="flex items-center justify-between mb-4">
                <h3 class="font-semibold text-white">📊 Tasa de Recuperación</h3>
                <span class="text-2xl font-bold text-green-400"><%= @recovery_rate %>%</span>
              </div>

              <div class="h-4 bg-slate-700 rounded-full overflow-hidden">
                <div
                  class="h-full bg-gradient-to-r from-green-600 to-green-400 transition-all duration-500"
                  style={"width: #{@recovery_rate}%"}
                >
                </div>
              </div>

              <div class="flex justify-between text-xs text-slate-500 mt-2">
                <span>0%</span>
                <span>Target: 95%</span>
                <span>100%</span>
              </div>
            </div>

            <!-- Detailed Stats -->
            <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-4">
              <h3 class="font-semibold text-white mb-4">📈 Estadísticas Detalladas</h3>

              <div class="grid grid-cols-2 md:grid-cols-3 gap-4">
                <.detail_stat label="Crashes" value={@stats.crashes} total={@stats.total_injections} />
                <.detail_stat label="Timeouts" value={@stats.timeouts} total={@stats.total_injections} />
                <.detail_stat label="Errors" value={@stats.errors} total={@stats.total_injections} />
                <.detail_stat label="Latencies" value={@stats.latencies} total={@stats.total_injections} />
                <.detail_stat
                  label="Comp Failures"
                  value={@stats.compensation_failures}
                  total={@stats.total_injections}
                />
                <div class="text-center">
                  <div class="text-sm text-slate-400">Uptime</div>
                  <div class="text-xl font-bold text-white"><%= format_uptime(@stats.uptime_seconds) %></div>
                </div>
              </div>
            </div>

            <!-- Event Feed -->
            <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 overflow-hidden">
              <div class="flex items-center justify-between p-4 border-b border-slate-700/50">
                <h3 class="font-semibold text-white">📡 Eventos de Chaos en Vivo</h3>
                <span :if={@chaos_enabled} class="flex items-center gap-2 text-sm text-green-400">
                  <span class="w-2 h-2 bg-green-500 rounded-full animate-pulse"></span>
                  Activo
                </span>
              </div>

              <div
                id="chaos-events"
                phx-update="stream"
                class="divide-y divide-slate-700/50 max-h-[300px] overflow-y-auto"
              >
                <div
                  :for={{dom_id, event} <- @streams.chaos_events}
                  id={dom_id}
                  class="p-3 hover:bg-slate-700/30 transition-colors flex items-center gap-3"
                >
                  <span class="text-lg"><%= event_icon(event.type) %></span>
                  <div class="flex-1">
                    <span class="font-medium text-white"><%= format_event_type(event.type) %></span>
                    <span class="text-slate-400 text-sm ml-2">→ <%= event.target %></span>
                  </div>
                  <span class="text-xs text-slate-500">
                    <%= format_time(event.timestamp) %>
                  </span>
                </div>
              </div>

              <div
                :if={@event_count == 0}
                class="p-8 text-center text-slate-500"
              >
                <div class="text-3xl mb-2">🐒</div>
                <p>No hay eventos de chaos recientes</p>
                <p :if={!@chaos_enabled} class="text-sm mt-1">Activa ChaosMonkey para comenzar</p>
              </div>
            </div>

            <!-- Idempotency Report -->
            <div class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-4">
              <h3 class="font-semibold text-white mb-4">🔄 Reporte de Idempotencia</h3>

              <div class="grid grid-cols-2 md:grid-cols-4 gap-4 text-center">
                <div>
                  <div class="text-2xl font-bold text-white"><%= @idempotency.total_validations %></div>
                  <div class="text-sm text-slate-400">Validaciones</div>
                </div>
                <div>
                  <div class="text-2xl font-bold text-green-400"><%= @idempotency.idempotent %></div>
                  <div class="text-sm text-slate-400">Idempotentes</div>
                </div>
                <div>
                  <div class="text-2xl font-bold text-red-400"><%= @idempotency.not_idempotent %></div>
                  <div class="text-sm text-slate-400">No Idempotentes</div>
                </div>
                <div>
                  <div class="text-2xl font-bold text-blue-400"><%= @idempotency.rate %>%</div>
                  <div class="text-sm text-slate-400">Tasa</div>
                </div>
              </div>
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

  attr :enabled, :boolean, required: true

  defp chaos_toggle(assigns) do
    ~H"""
    <button
      phx-click="toggle_chaos"
      class={[
        "px-6 py-3 rounded-xl font-semibold transition-all flex items-center gap-3",
        @enabled && "bg-red-600 text-white hover:bg-red-700 shadow-lg shadow-red-900/50",
        !@enabled && "bg-slate-700 text-slate-300 hover:bg-slate-600"
      ]}
    >
      <span class="text-2xl">🐒</span>
      <span><%= if @enabled, do: "Desactivar Chaos", else: "Activar Chaos" %></span>
    </button>
    """
  end

  attr :profile, :atom, required: true
  attr :current, :atom, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true
  attr :color, :string, required: true

  defp profile_button(assigns) do
    is_selected = assigns.profile == assigns.current

    border_color =
      case assigns.color do
        "green" -> "border-green-500/50"
        "yellow" -> "border-yellow-500/50"
        "red" -> "border-red-500/50"
        _ -> "border-slate-700/50"
      end

    assigns = assign(assigns, is_selected: is_selected, border_color: border_color)

    ~H"""
    <button
      phx-click="set_profile"
      phx-value-profile={@profile}
      class={[
        "w-full p-3 rounded-lg border transition text-left",
        @is_selected && "#{@border_color} bg-slate-700/50",
        !@is_selected && "border-slate-700/50 hover:border-slate-600"
      ]}
    >
      <div class="flex items-center justify-between">
        <span class="font-medium text-white"><%= @label %></span>
        <span :if={@is_selected} class="text-green-400">✓</span>
      </div>
      <div class="text-xs text-slate-400 mt-1"><%= @description %></div>
    </button>
    """
  end

  attr :type, :atom, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :enabled, :boolean, required: true
  attr :class, :string, default: ""

  defp inject_button(assigns) do
    ~H"""
    <button
      phx-click="inject_fault"
      phx-value-type={@type}
      disabled={!@enabled}
      class={[
        "p-3 rounded-lg border transition flex flex-col items-center gap-1",
        @enabled && "border-slate-700/50 bg-slate-700/30 hover:bg-slate-700 text-white",
        !@enabled && "border-slate-800 bg-slate-800/50 text-slate-600 cursor-not-allowed",
        @class
      ]}
    >
      <span class="text-2xl"><%= @icon %></span>
      <span class="text-xs"><%= @label %></span>
    </button>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :color, :string, required: true

  defp stat_card(assigns) do
    bg_class =
      case assigns.color do
        "blue" -> "from-blue-600/20 to-blue-800/10 border-blue-500/30"
        "red" -> "from-red-600/20 to-red-800/10 border-red-500/30"
        "green" -> "from-green-600/20 to-green-800/10 border-green-500/30"
        "orange" -> "from-orange-600/20 to-orange-800/10 border-orange-500/30"
        _ -> "from-slate-600/20 to-slate-800/10 border-slate-500/30"
      end

    assigns = assign(assigns, bg_class: bg_class)

    ~H"""
    <div class={"p-4 rounded-xl bg-gradient-to-br border #{@bg_class}"}>
      <div class="text-2xl mb-1"><%= @icon %></div>
      <div class="text-2xl font-bold text-white"><%= @value %></div>
      <div class="text-xs text-slate-400"><%= @label %></div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :total, :integer, required: true

  defp detail_stat(assigns) do
    percentage = if assigns.total > 0, do: Float.round(assigns.value / assigns.total * 100, 1), else: 0
    assigns = assign(assigns, percentage: percentage)

    ~H"""
    <div class="text-center">
      <div class="text-sm text-slate-400"><%= @label %></div>
      <div class="text-xl font-bold text-white"><%= @value %></div>
      <div class="text-xs text-slate-500"><%= @percentage %>%</div>
    </div>
    """
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_chaos_state(socket) do
    stats =
      try do
        ChaosMonkey.stats()
      rescue
        _ -> default_stats()
      end

    {profile, _config} =
      try do
        ChaosMonkey.current_profile()
      rescue
        _ -> {:gentle, %{}}
      end

    enabled = Map.get(stats, :enabled, false)
    uptime = Map.get(stats, :uptime_seconds, 0)

    recovery_rate = calculate_recovery_rate(stats)

    socket
    |> assign(chaos_enabled: enabled)
    |> assign(current_profile: profile)
    |> assign(stats: Map.put(stats, :uptime_seconds, uptime))
    |> assign(recovery_rate: recovery_rate)
  end

  defp load_idempotency_report(socket) do
    report =
      try do
        IdempotencyValidator.report()
      rescue
        _ -> %{stats: %{total_validations: 0, idempotent: 0, not_idempotent: 0}, idempotency_rate: 0}
      end

    idempotency = %{
      total_validations: report.stats.total_validations,
      idempotent: report.stats.idempotent,
      not_idempotent: report.stats.not_idempotent,
      rate: report.idempotency_rate
    }

    assign(socket, idempotency: idempotency)
  end

  defp default_stats do
    %{
      total_injections: 0,
      crashes: 0,
      timeouts: 0,
      errors: 0,
      latencies: 0,
      compensation_failures: 0,
      successful_recoveries: 0,
      failed_recoveries: 0,
      uptime_seconds: 0,
      enabled: false
    }
  end

  defp calculate_recovery_rate(stats) do
    total = Map.get(stats, :successful_recoveries, 0) + Map.get(stats, :failed_recoveries, 0)

    if total > 0 do
      Float.round(Map.get(stats, :successful_recoveries, 0) / total * 100, 1)
    else
      100.0
    end
  end

  defp event_icon(:crash), do: "💥"
  defp event_icon(:timeout), do: "⏰"
  defp event_icon(:error), do: "❌"
  defp event_icon(:latency), do: "🐢"
  defp event_icon(:compensation_fail), do: "🔄"
  defp event_icon(_), do: "🐒"

  defp format_event_type(:crash), do: "Crash"
  defp format_event_type(:timeout), do: "Timeout"
  defp format_event_type(:error), do: "Error"
  defp format_event_type(:latency), do: "Latency"
  defp format_event_type(:compensation_fail), do: "Compensation Fail"
  defp format_event_type(type), do: to_string(type)

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_time(_), do: "-"

  defp format_uptime(seconds) when is_number(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  defp format_uptime(_), do: "0s"
end
