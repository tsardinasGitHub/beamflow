defmodule BeamflowWeb.AnalyticsLive do
  @moduledoc """
  Dashboard de Analytics para Beamflow.

  Visualiza métricas de rendimiento, tendencias y estadísticas de workflows
  con gráficos SVG interactivos y actualizaciones en tiempo real.

  ## Secciones

  1. **KPIs** - Métricas clave con indicadores visuales
  2. **Tendencias** - Gráficos de workflows por hora/día
  3. **Rendimiento** - Tiempos de ejecución con percentiles
  4. **Por Módulo** - Comparación entre tipos de workflow
  5. **Steps Problemáticos** - Top steps con mayor tasa de fallo
  """

  use BeamflowWeb, :live_view

  alias Beamflow.Analytics.WorkflowAnalytics

  @refresh_interval 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Refresh automático cada 10 segundos
      :timer.send_interval(@refresh_interval, self(), :refresh_metrics)
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "workflows")
    end

    socket =
      socket
      |> assign(page_title: "Analytics")
      |> assign(loading: true)
      |> assign(last_updated: DateTime.utc_now())
      |> assign(filter_range: :all)
      |> assign(custom_date: nil)
      |> assign(is_sampled: false)
      |> assign(sparklines: %{completed: [], failed: [], total: []})
      |> assign(weekly_heatmap: [])
      |> load_all_metrics()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_metrics, socket) do
    {:noreply, load_all_metrics(socket)}
  end

  @impl true
  def handle_info({:workflow_updated, _}, socket) do
    # Debounce: solo actualizar si han pasado más de 2 segundos
    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:last_refresh] || 0

    if now - last > 2000 do
      {:noreply, socket |> assign(last_refresh: now) |> load_all_metrics()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_all_metrics(socket)}
  end

  @impl true
  def handle_event("filter", %{"range" => range}, socket) do
    filter_range = String.to_existing_atom(range)
    socket = socket
      |> assign(filter_range: filter_range)
      |> assign(custom_date: nil)
      |> load_all_metrics()
    {:noreply, socket}
  end

  @impl true
  def handle_event("heatmap_click", %{"date" => date_str}, socket) do
    # Parse date and set custom filter
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        socket = socket
          |> assign(filter_range: :custom)
          |> assign(custom_date: date)
          |> load_all_metrics()
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_custom_date", _params, socket) do
    socket = socket
      |> assign(filter_range: :all)
      |> assign(custom_date: nil)
      |> load_all_metrics()
    {:noreply, socket}
  end

  @impl true
  def handle_event("export", %{"format" => format}, socket) do
    format_atom = String.to_existing_atom(format)
    opts = build_filter_opts(socket.assigns.filter_range)

    data = WorkflowAnalytics.export_metrics(opts)
    content = format_export(data, format_atom)

    filename = "beamflow_analytics_#{Date.utc_today()}.#{format}"

    {:noreply, push_event(socket, "download", %{content: content, filename: filename, mime: mime_type(format_atom)})}
  end

  defp format_export(data, :json), do: Jason.encode!(data, pretty: true)
  defp format_export(data, :csv) do
    # Disclaimer si hay sampling
    disclaimer = if Map.get(data, :_disclaimer) do
      "# #{data._disclaimer}\n# Muestra: #{data._sample_info.sample_size} registros\n\n"
    else
      ""
    end

    # CSV del summary
    summary_csv = "Metric,Value\n" <>
      Enum.map_join(data.summary, "\n", fn {k, v} -> "#{k},#{v}" end)

    # CSV de performance
    perf_csv = "\n\nPerformance Metric,Value\n" <>
      Enum.map_join(data.performance, "\n", fn {k, v} -> "#{k},#{v}" end)

    disclaimer <> summary_csv <> perf_csv
  end

  defp mime_type(:json), do: "application/json"
  defp mime_type(:csv), do: "text/csv"

  defp build_filter_opts(:all), do: []
  defp build_filter_opts(:custom), do: []  # Handled separately with custom_date
  defp build_filter_opts(:today) do
    now = DateTime.utc_now()
    date_from = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])
    date_to = DateTime.add(date_from, 86400, :second)
    [date_from: date_from, date_to: date_to]
  end
  defp build_filter_opts(:week) do
    now = DateTime.utc_now()
    date_from = DateTime.add(now, -7 * 86400, :second)
    [date_from: date_from, date_to: now]
  end
  defp build_filter_opts(:month) do
    now = DateTime.utc_now()
    date_from = DateTime.add(now, -30 * 86400, :second)
    [date_from: date_from, date_to: now]
  end

  defp build_filter_opts_with_custom(filter_range, custom_date) do
    case {filter_range, custom_date} do
      {:custom, %Date{} = date} ->
        date_from = DateTime.new!(date, ~T[00:00:00])
        date_to = DateTime.add(date_from, 86400, :second)
        [date_from: date_from, date_to: date_to]

      _ ->
        build_filter_opts(filter_range)
    end
  end

  # Sparkline hours based on filter range
  defp sparkline_hours(:today), do: 6
  defp sparkline_hours(:week), do: 7   # 7 days
  defp sparkline_hours(:month), do: 30  # 30 days
  defp sparkline_hours(:custom), do: 24  # Full day in hours
  defp sparkline_hours(_), do: 12  # Default

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900" id="analytics-container" phx-hook="DownloadHook">
      <!-- Header -->
      <header class="border-b border-slate-700/50 bg-slate-900/50 backdrop-blur-sm sticky top-0 z-10">
        <div class="max-w-7xl mx-auto px-6 py-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <a href="/" class="text-slate-400 hover:text-white transition-colors">
                ← Dashboard
              </a>
              <div class="h-6 w-px bg-slate-700"></div>
              <div>
                <h1 class="text-2xl font-bold text-white flex items-center gap-2">
                  📈 Analytics
                </h1>
                <p class="text-slate-400 text-sm">Métricas y tendencias de workflows</p>
              </div>
            </div>

            <div class="flex items-center gap-4">
              <!-- Filter Controls -->
              <div class="flex items-center gap-2 bg-slate-800 rounded-lg p-1">
                <button
                  phx-click="filter"
                  phx-value-range="all"
                  class={"px-3 py-1.5 rounded text-sm transition-colors " <>
                    if(@filter_range == :all, do: "bg-blue-600 text-white", else: "text-slate-400 hover:text-white")}
                >
                  Todo
                </button>
                <button
                  phx-click="filter"
                  phx-value-range="today"
                  class={"px-3 py-1.5 rounded text-sm transition-colors " <>
                    if(@filter_range == :today, do: "bg-blue-600 text-white", else: "text-slate-400 hover:text-white")}
                >
                  Hoy
                </button>
                <button
                  phx-click="filter"
                  phx-value-range="week"
                  class={"px-3 py-1.5 rounded text-sm transition-colors " <>
                    if(@filter_range == :week, do: "bg-blue-600 text-white", else: "text-slate-400 hover:text-white")}
                >
                  Semana
                </button>
                <button
                  phx-click="filter"
                  phx-value-range="month"
                  class={"px-3 py-1.5 rounded text-sm transition-colors " <>
                    if(@filter_range == :month, do: "bg-blue-600 text-white", else: "text-slate-400 hover:text-white")}
                >
                  Mes
                </button>
              </div>

              <!-- Custom Date Indicator -->
              <%= if @custom_date do %>
                <div class="flex items-center gap-2 bg-purple-600/20 border border-purple-500/30 rounded-lg px-3 py-1.5">
                  <span class="text-purple-300 text-sm">📅 <%= @custom_date %></span>
                  <button
                    phx-click="clear_custom_date"
                    class="text-purple-400 hover:text-white transition-colors"
                    title="Limpiar filtro"
                  >
                    ✕
                  </button>
                </div>
              <% end %>

              <div class="h-6 w-px bg-slate-700"></div>

              <!-- Export Controls -->
              <div class="flex items-center gap-2">
                <button
                  phx-click="export"
                  phx-value-format="json"
                  class="px-3 py-2 bg-slate-700 hover:bg-slate-600 text-slate-300 rounded-lg transition-colors flex items-center gap-2 text-sm"
                >
                  <span>📄</span> JSON
                </button>
                <button
                  phx-click="export"
                  phx-value-format="csv"
                  class="px-3 py-2 bg-slate-700 hover:bg-slate-600 text-slate-300 rounded-lg transition-colors flex items-center gap-2 text-sm"
                >
                  <span>📊</span> CSV
                </button>
              </div>

              <div class="h-6 w-px bg-slate-700"></div>

              <span class="text-sm text-slate-500">
                Actualizado: <%= format_time(@last_updated) %>
              </span>
              <button
                phx-click="refresh"
                class="px-4 py-2 bg-blue-600 hover:bg-blue-500 text-white rounded-lg transition-colors flex items-center gap-2"
              >
                <span class="text-lg">🔄</span>
                Actualizar
              </button>
            </div>
          </div>
        </div>
      </header>

      <main class="max-w-7xl mx-auto px-6 py-8 space-y-8">
        <!-- Sampling Warning -->
        <%= if @is_sampled do %>
          <div class="bg-amber-900/30 border border-amber-600/30 rounded-lg p-4 flex items-center gap-3">
            <span class="text-2xl">⚠️</span>
            <div>
              <p class="text-amber-200 font-medium">Datos muestreados</p>
              <p class="text-amber-300/70 text-sm">Las métricas se calculan sobre una muestra representativa para optimizar el rendimiento.</p>
            </div>
          </div>
        <% end %>

        <!-- KPIs Row with Sparklines -->
        <section>
          <h2 class="text-lg font-semibold text-slate-300 mb-4">📊 Resumen General</h2>
          <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-7 gap-4">
            <.kpi_card_with_sparkline
              label="Total"
              value={@summary.total}
              icon="📋"
              color="slate"
              sparkline={@sparklines.total}
            />
            <.kpi_card_with_sparkline
              label="Completados"
              value={@summary.completed}
              icon="✅"
              color="green"
              sparkline={@sparklines.completed}
            />
            <.kpi_card_with_sparkline
              label="Fallidos"
              value={@summary.failed}
              icon="❌"
              color="red"
              sparkline={@sparklines.failed}
            />
            <.kpi_card
              label="En Progreso"
              value={@summary.running}
              icon="🔄"
              color="blue"
            />
            <.kpi_card
              label="Pendientes"
              value={@summary.pending}
              icon="⏳"
              color="yellow"
            />
            <.success_rate_card rate={@summary.success_rate} />
            <.failure_rate_card rate={@summary.failure_rate} />
          </div>
        </section>

        <!-- Activity Heatmap -->
        <section class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-6">
          <h3 class="text-lg font-semibold text-white mb-4">🗓️ Actividad (Últimas 7 semanas)</h3>
          <.activity_heatmap data={@weekly_heatmap} />
        </section>

        <!-- Charts Row -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Daily Trend -->
          <section class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-6">
            <h3 class="text-lg font-semibold text-white mb-4">📅 Últimos 7 Días</h3>
            <.daily_chart data={@daily_trend} />
          </section>

          <!-- Hourly Trend -->
          <section class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-6">
            <h3 class="text-lg font-semibold text-white mb-4">🕐 Últimas 24 Horas</h3>
            <.hourly_chart data={@hourly_trend} />
          </section>
        </div>

        <!-- Performance Metrics -->
        <section class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-6">
          <h3 class="text-lg font-semibold text-white mb-4">⚡ Rendimiento</h3>
          <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
            <.perf_metric label="Promedio" value={@performance.avg_duration_ms} unit="ms" />
            <.perf_metric label="Mínimo" value={@performance.min_duration_ms} unit="ms" />
            <.perf_metric label="Máximo" value={@performance.max_duration_ms} unit="ms" />
            <.perf_metric label="P50 (Mediana)" value={@performance.p50} unit="ms" highlight={true} />
            <.perf_metric label="P95" value={@performance.p95} unit="ms" />
            <.perf_metric label="P99" value={@performance.p99} unit="ms" />
          </div>
          <div class="mt-4 text-sm text-slate-500">
            Basado en <%= @performance.sample_size %> workflows completados
          </div>
        </section>

        <!-- Two Column Layout -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- By Module -->
          <section class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-6">
            <h3 class="text-lg font-semibold text-white mb-4">📦 Por Tipo de Workflow</h3>
            <.module_table modules={@by_module} />
          </section>

          <!-- Problem Steps -->
          <section class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-6">
            <h3 class="text-lg font-semibold text-white mb-4">⚠️ Steps Problemáticos</h3>
            <.step_table steps={@step_performance} />
          </section>
        </div>

        <!-- Recent Failures -->
        <section class="bg-slate-800/50 rounded-xl border border-slate-700/50 p-6">
          <h3 class="text-lg font-semibold text-white mb-4">🔴 Fallos Recientes</h3>
          <.failures_table failures={@recent_failures} />
        </section>
      </main>
    </div>
    """
  end

  # ============================================================================
  # Components
  # ============================================================================

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true
  attr :color, :string, required: true

  defp kpi_card(assigns) do
    bg = case assigns.color do
      "green" -> "from-green-600/20 to-green-800/10 border-green-500/30"
      "red" -> "from-red-600/20 to-red-800/10 border-red-500/30"
      "blue" -> "from-blue-600/20 to-blue-800/10 border-blue-500/30"
      "yellow" -> "from-yellow-600/20 to-yellow-800/10 border-yellow-500/30"
      _ -> "from-slate-600/20 to-slate-800/10 border-slate-500/30"
    end

    assigns = assign(assigns, :bg, bg)

    ~H"""
    <div class={"p-4 rounded-xl bg-gradient-to-br border #{@bg}"}>
      <div class="text-2xl mb-1"><%= @icon %></div>
      <div class="text-2xl font-bold text-white"><%= format_number(@value) %></div>
      <div class="text-sm text-slate-400"><%= @label %></div>
    </div>
    """
  end

  # KPI Card with Sparkline
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true
  attr :color, :string, required: true
  attr :sparkline, :list, required: true

  defp kpi_card_with_sparkline(assigns) do
    bg = case assigns.color do
      "green" -> "from-emerald-600/20 to-emerald-800/10 border-emerald-500/30"
      "red" -> "from-red-600/20 to-red-800/10 border-red-500/30"
      "blue" -> "from-blue-600/20 to-blue-800/10 border-blue-500/30"
      "yellow" -> "from-amber-600/20 to-amber-800/10 border-amber-500/30"
      _ -> "from-slate-600/20 to-slate-800/10 border-slate-500/30"
    end

    stroke_color = case assigns.color do
      "green" -> "#10b981"
      "red" -> "#ef4444"
      "blue" -> "#3b82f6"
      "yellow" -> "#f59e0b"
      _ -> "#64748b"
    end

    assigns = assigns
      |> assign(:bg, bg)
      |> assign(:stroke_color, stroke_color)
      |> assign(:sparkline_path, build_sparkline_path(assigns.sparkline))

    ~H"""
    <div class={"p-4 rounded-xl bg-gradient-to-br border #{@bg}"}>
      <div class="flex items-start justify-between">
        <div class="text-2xl"><%= @icon %></div>
        <!-- Mini Sparkline -->
        <svg class="w-16 h-6" viewBox="0 0 64 24" preserveAspectRatio="none">
          <path
            d={@sparkline_path}
            fill="none"
            stroke={@stroke_color}
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            class="opacity-60"
          />
        </svg>
      </div>
      <div class="text-2xl font-bold text-white mt-1"><%= format_number(@value) %></div>
      <div class="text-sm text-slate-400"><%= @label %></div>
    </div>
    """
  end

  # Activity Heatmap (GitHub style)
  attr :data, :list, required: true

  defp activity_heatmap(assigns) do
    # Group by week
    weeks = assigns.data
      |> Enum.group_by(& &1.week)
      |> Enum.sort_by(fn {week, _} -> week end)

    day_labels = ["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"]

    assigns = assigns
      |> assign(:weeks, weeks)
      |> assign(:day_labels, day_labels)

    ~H"""
    <div class="flex gap-1">
      <!-- Day labels -->
      <div class="flex flex-col gap-1 mr-2">
        <%= for {label, idx} <- Enum.with_index(@day_labels) do %>
          <div class={"w-8 h-4 text-xs text-slate-500 text-right pr-1 #{if rem(idx, 2) == 0, do: "opacity-100", else: "opacity-0"}"}>
            <%= label %>
          </div>
        <% end %>
      </div>

      <!-- Heatmap grid - Clickeable cells -->
      <div class="flex gap-1">
        <%= for {_week, days} <- @weeks do %>
          <div class="flex flex-col gap-1">
            <%= for day <- Enum.sort_by(days, & &1.day) do %>
              <div
                phx-click="heatmap_click"
                phx-value-date={Date.to_iso8601(day.date)}
                class={"w-4 h-4 rounded-sm transition-all cursor-pointer hover:ring-2 hover:ring-white/50 hover:scale-110 " <> heatmap_color(day.intensity)}
                title={"#{day.date}: #{day.count} workflows - Click para filtrar"}
              ></div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>

    <!-- Legend -->
    <div class="flex items-center justify-between mt-4">
      <div class="flex items-center gap-2 text-xs text-slate-500">
        <span>Menos</span>
        <div class="w-3 h-3 rounded-sm bg-slate-800"></div>
        <div class="w-3 h-3 rounded-sm bg-emerald-900"></div>
        <div class="w-3 h-3 rounded-sm bg-emerald-700"></div>
        <div class="w-3 h-3 rounded-sm bg-emerald-500"></div>
        <div class="w-3 h-3 rounded-sm bg-emerald-400"></div>
        <span>Más</span>
      </div>
      <span class="text-xs text-slate-500 italic">Click en celda para ver ese día</span>
    </div>
    """
  end

  defp heatmap_color(0), do: "bg-slate-800"
  defp heatmap_color(1), do: "bg-emerald-900"
  defp heatmap_color(2), do: "bg-emerald-700"
  defp heatmap_color(3), do: "bg-emerald-500"
  defp heatmap_color(4), do: "bg-emerald-400"
  defp heatmap_color(_), do: "bg-emerald-400"

  defp build_sparkline_path([]), do: "M0,12 L64,12"
  defp build_sparkline_path(data) when is_list(data) and length(data) > 0 do
    max_val = Enum.max(data) |> max(1)
    points = data
      |> Enum.with_index()
      |> Enum.map(fn {val, idx} ->
        x = idx * (64 / max(length(data) - 1, 1))
        y = 22 - (val / max_val * 20)
        {x, y}
      end)

    [{first_x, first_y} | rest] = points
    path_start = "M#{Float.round(first_x, 1)},#{Float.round(first_y, 1)}"

    rest
    |> Enum.reduce(path_start, fn {x, y}, acc ->
      acc <> " L#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
  end
  defp build_sparkline_path(_), do: "M0,12 L64,12"

  attr :rate, :float, required: true

  defp success_rate_card(assigns) do
    percentage = round(assigns.rate * 100)
    assigns = assign(assigns, :percentage, percentage)

    ~H"""
    <div class="p-4 rounded-xl bg-gradient-to-br from-emerald-600/20 to-emerald-800/10 border border-emerald-500/30">
      <div class="flex items-center justify-between mb-2">
        <span class="text-sm text-slate-400">Tasa de Éxito</span>
      </div>
      <div class="relative pt-1">
        <div class="flex items-center justify-between mb-1">
          <span class="text-2xl font-bold text-emerald-400"><%= @percentage %>%</span>
        </div>
        <div class="w-full bg-slate-700 rounded-full h-2">
          <div
            class="bg-emerald-500 h-2 rounded-full transition-all duration-500"
            style={"width: #{@percentage}%"}
          ></div>
        </div>
      </div>
    </div>
    """
  end

  attr :rate, :float, required: true

  defp failure_rate_card(assigns) do
    percentage = round(assigns.rate * 100)
    assigns = assign(assigns, :percentage, percentage)

    ~H"""
    <div class="p-4 rounded-xl bg-gradient-to-br from-red-600/20 to-red-800/10 border border-red-500/30">
      <div class="flex items-center justify-between mb-2">
        <span class="text-sm text-slate-400">Tasa de Fallo</span>
      </div>
      <div class="relative pt-1">
        <div class="flex items-center justify-between mb-1">
          <span class="text-2xl font-bold text-red-400"><%= @percentage %>%</span>
        </div>
        <div class="w-full bg-slate-700 rounded-full h-2">
          <div
            class="bg-red-500 h-2 rounded-full transition-all duration-500"
            style={"width: #{@percentage}%"}
          ></div>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :unit, :string, required: true
  attr :highlight, :boolean, default: false

  defp perf_metric(assigns) do
    ~H"""
    <div class={[
      "p-4 rounded-lg text-center",
      @highlight && "bg-blue-600/20 border border-blue-500/30",
      !@highlight && "bg-slate-700/30"
    ]}>
      <div class="text-2xl font-bold text-white">
        <%= format_duration(@value) %>
      </div>
      <div class="text-sm text-slate-400"><%= @label %></div>
    </div>
    """
  end

  attr :data, :list, required: true

  defp daily_chart(assigns) do
    max_value = assigns.data |> Enum.map(& &1.total) |> Enum.max(fn -> 1 end) |> max(1)
    assigns = assign(assigns, :max_value, max_value)

    ~H"""
    <div class="space-y-2">
      <%= for day <- @data do %>
        <div class="flex items-center gap-3">
          <div class="w-16 text-sm text-slate-400 text-right"><%= day.label %></div>
          <div class="flex-1 flex items-center gap-1 h-6">
            <!-- Completed bar -->
            <div
              class="bg-emerald-500 h-full rounded-l transition-all duration-500"
              style={"width: #{bar_width(day.completed, @max_value)}%"}
              title={"Completados: #{day.completed}"}
            ></div>
            <!-- Failed bar -->
            <div
              class="bg-red-500 h-full rounded-r transition-all duration-500"
              style={"width: #{bar_width(day.failed, @max_value)}%"}
              title={"Fallidos: #{day.failed}"}
            ></div>
          </div>
          <div class="w-12 text-sm text-slate-400 text-right"><%= day.total %></div>
        </div>
      <% end %>
      <div class="flex items-center gap-4 mt-4 text-xs text-slate-500">
        <div class="flex items-center gap-1">
          <div class="w-3 h-3 bg-emerald-500 rounded"></div>
          <span>Completados</span>
        </div>
        <div class="flex items-center gap-1">
          <div class="w-3 h-3 bg-red-500 rounded"></div>
          <span>Fallidos</span>
        </div>
      </div>
    </div>
    """
  end

  attr :data, :list, required: true

  defp hourly_chart(assigns) do
    max_value = assigns.data |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end) |> max(1)
    assigns = assign(assigns, :max_value, max_value)

    ~H"""
    <div class="h-40 flex items-end gap-1">
      <%= for hour <- @data do %>
        <div
          class="flex-1 bg-blue-500 rounded-t transition-all duration-300 hover:bg-blue-400 cursor-pointer relative group"
          style={"height: #{bar_height(hour.count, @max_value)}%"}
        >
          <div class="absolute -top-8 left-1/2 -translate-x-1/2 bg-slate-900 text-white text-xs px-2 py-1 rounded opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap">
            <%= hour.label %>: <%= hour.count %>
          </div>
        </div>
      <% end %>
    </div>
    <div class="flex justify-between mt-2 text-xs text-slate-500">
      <span>-24h</span>
      <span>-12h</span>
      <span>Ahora</span>
    </div>
    """
  end

  attr :modules, :list, required: true

  defp module_table(assigns) do
    ~H"""
    <div class="space-y-2">
      <%= if Enum.empty?(@modules) do %>
        <div class="text-center text-slate-500 py-4">
          No hay datos de módulos
        </div>
      <% else %>
        <%= for mod <- @modules do %>
          <div class="flex items-center gap-3 p-3 bg-slate-700/30 rounded-lg">
            <div class="flex-1">
              <div class="font-medium text-white"><%= mod.module %></div>
              <div class="text-sm text-slate-400">
                <%= mod.completed %> completados, <%= mod.failed %> fallidos
              </div>
            </div>
            <div class="text-right">
              <div class={"text-lg font-bold #{success_color(mod.success_rate)}"}>
                <%= round(mod.success_rate * 100) %>%
              </div>
              <div class="text-xs text-slate-500"><%= mod.total %> total</div>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :steps, :list, required: true

  defp step_table(assigns) do
    ~H"""
    <div class="space-y-2">
      <%= if Enum.empty?(@steps) do %>
        <div class="text-center text-slate-500 py-4">
          No hay datos de steps
        </div>
      <% else %>
        <%= for step <- @steps do %>
          <div class="flex items-center gap-3 p-3 bg-slate-700/30 rounded-lg">
            <div class={[
              "w-2 h-full rounded-full",
              step.failure_rate > 0.2 && "bg-red-500",
              step.failure_rate > 0.05 && step.failure_rate <= 0.2 && "bg-yellow-500",
              step.failure_rate <= 0.05 && "bg-green-500"
            ]}></div>
            <div class="flex-1">
              <div class="font-medium text-white"><%= step.step %></div>
              <div class="text-sm text-slate-400">
                <%= step.total_executions %> ejecuciones · <%= format_duration(step.avg_duration_ms) %> avg
              </div>
            </div>
            <div class="text-right">
              <div class={"text-lg font-bold #{failure_color(step.failure_rate)}"}>
                <%= round(step.failure_rate * 100) %>%
              </div>
              <div class="text-xs text-slate-500"><%= step.failures %> fallos</div>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :failures, :list, required: true

  defp failures_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <%= if Enum.empty?(@failures) do %>
        <div class="text-center text-slate-500 py-8">
          <div class="text-4xl mb-2">✅</div>
          <p>No hay fallos recientes</p>
        </div>
      <% else %>
        <table class="w-full">
          <thead>
            <tr class="text-left text-sm text-slate-400 border-b border-slate-700">
              <th class="pb-3 pr-4">Workflow ID</th>
              <th class="pb-3 pr-4">Módulo</th>
              <th class="pb-3 pr-4">Step</th>
              <th class="pb-3 pr-4">Error</th>
              <th class="pb-3">Fecha</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-slate-700/50">
            <%= for failure <- @failures do %>
              <tr class="hover:bg-slate-700/30">
                <td class="py-3 pr-4">
                  <a
                    href={"/workflows/#{failure.workflow_id}"}
                    class="text-blue-400 hover:text-blue-300 font-mono text-sm"
                  >
                    <%= truncate_id(failure.workflow_id) %>
                  </a>
                </td>
                <td class="py-3 pr-4 text-white"><%= failure.module %></td>
                <td class="py-3 pr-4 text-slate-400">Step <%= failure.step_index %></td>
                <td class="py-3 pr-4 text-red-400 text-sm max-w-xs truncate">
                  <%= failure.error %>
                </td>
                <td class="py-3 text-slate-500 text-sm">
                  <%= format_datetime(failure.failed_at) %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_all_metrics(socket) do
    filter_range = socket.assigns[:filter_range] || :all
    custom_date = socket.assigns[:custom_date]
    opts = build_filter_opts_with_custom(filter_range, custom_date)

    # Sparkline hours adaptativos según el filtro
    sparkline_hrs = sparkline_hours(filter_range)
    sparkline_unit = if filter_range in [:week, :month], do: :day, else: :hour

    metrics = WorkflowAnalytics.dashboard_metrics(opts)

    # Obtener sparklines adaptativos
    sparklines = WorkflowAnalytics.adaptive_sparklines(sparkline_hrs, sparkline_unit)

    socket
    |> assign(loading: false)
    |> assign(last_updated: DateTime.utc_now())
    |> assign(is_sampled: Map.get(metrics, :is_sampled, false))
    |> assign(summary: metrics.summary)
    |> assign(performance: metrics.performance)
    |> assign(hourly_trend: metrics.hourly_trend)
    |> assign(daily_trend: metrics.daily_trend)
    |> assign(weekly_heatmap: metrics.weekly_heatmap)
    |> assign(sparklines: sparklines)
    |> assign(by_module: metrics.by_module)
    |> assign(step_performance: metrics.step_performance)
    |> assign(recent_failures: metrics.recent_failures)
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)

  defp format_duration(ms) when ms >= 60_000, do: "#{Float.round(ms / 60_000, 1)}m"
  defp format_duration(ms) when ms >= 1_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp format_duration(ms), do: "#{ms}ms"

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: "-"

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(_), do: "-"

  defp truncate_id(id) when is_binary(id) and byte_size(id) > 12 do
    String.slice(id, 0, 12) <> "..."
  end
  defp truncate_id(id), do: id

  defp bar_width(value, max) when max > 0, do: round(value / max * 100)
  defp bar_width(_, _), do: 0

  defp bar_height(value, max) when max > 0 and value > 0, do: max(round(value / max * 100), 5)
  defp bar_height(_, _), do: 0

  defp success_color(rate) when rate >= 0.9, do: "text-emerald-400"
  defp success_color(rate) when rate >= 0.7, do: "text-yellow-400"
  defp success_color(_), do: "text-red-400"

  defp failure_color(rate) when rate <= 0.05, do: "text-emerald-400"
  defp failure_color(rate) when rate <= 0.2, do: "text-yellow-400"
  defp failure_color(_), do: "text-red-400"
end
