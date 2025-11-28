defmodule Beamflow.Analytics.WorkflowAnalytics do
  @moduledoc """
  Motor de análisis para métricas de workflows.

  Proporciona cálculos de estadísticas, tendencias y métricas de rendimiento
  basados en los datos almacenados en Mnesia.

  ## Métricas Disponibles

  - **Resumen General**: totales, tasas de éxito/fallo
  - **Rendimiento**: tiempos promedio, percentiles
  - **Tendencias**: workflows por hora/día
  - **Por Step**: métricas desglosadas por cada paso
  - **Por Módulo**: comparación entre tipos de workflow

  ## Ejemplo de Uso

      iex> WorkflowAnalytics.summary()
      %{total: 150, completed: 120, failed: 10, running: 20, success_rate: 0.92}

      iex> WorkflowAnalytics.performance_metrics()
      %{avg_duration_ms: 2500, p50: 2000, p95: 5000, p99: 8000}
  """

  alias Beamflow.Storage.WorkflowStore

  # Límite de muestreo para evitar timeouts con grandes volúmenes
  @max_sample_size 1000
  @max_workflows_scan 500

  # ============================================================================
  # Funciones de Muestreo
  # ============================================================================

  @doc false
  defp maybe_sample(list) when length(list) <= @max_sample_size do
    Process.put(:analytics_sampled, false)
    list
  end

  defp maybe_sample(list) do
    Process.put(:analytics_sampled, true)
    list |> Enum.shuffle() |> Enum.take(@max_sample_size)
  end

  # ============================================================================
  # Resumen General
  # ============================================================================

  @doc """
  Calcula un resumen general de todos los workflows.

  Retorna conteos por estado y tasas de éxito/fallo.

  ## Opciones

  - `:date_from` - Fecha inicial (DateTime)
  - `:date_to` - Fecha final (DateTime)
  """
  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    date_from = Keyword.get(opts, :date_from)
    date_to = Keyword.get(opts, :date_to)

    stats = if date_from || date_to do
      count_by_status_in_range(date_from, date_to)
    else
      WorkflowStore.count_by_status()
    end

    total = stats.completed + stats.failed + stats.running + stats.pending
    success_rate = if total > 0, do: Float.round(stats.completed / total, 2), else: 0.0
    failure_rate = if total > 0, do: Float.round(stats.failed / total, 2), else: 0.0

    %{
      total: total,
      completed: stats.completed,
      failed: stats.failed,
      running: stats.running,
      pending: stats.pending,
      success_rate: success_rate,
      failure_rate: failure_rate
    }
  end

  # ============================================================================
  # Métricas de Rendimiento
  # ============================================================================

  @doc """
  Calcula métricas de rendimiento basadas en tiempos de ejecución.

  Incluye promedio, mediana (p50), p95 y p99.
  """
  @spec performance_metrics() :: map()
  def performance_metrics do
    durations = get_completed_durations()

    if Enum.empty?(durations) do
      %{
        avg_duration_ms: 0,
        min_duration_ms: 0,
        max_duration_ms: 0,
        p50: 0,
        p95: 0,
        p99: 0,
        sample_size: 0
      }
    else
      sorted = Enum.sort(durations)
      count = length(sorted)

      %{
        avg_duration_ms: round(Enum.sum(durations) / count),
        min_duration_ms: Enum.min(durations),
        max_duration_ms: Enum.max(durations),
        p50: percentile(sorted, 50),
        p95: percentile(sorted, 95),
        p99: percentile(sorted, 99),
        sample_size: count
      }
    end
  end

  @doc """
  Calcula métricas de rendimiento por step.

  Retorna una lista de maps con estadísticas por cada step.
  """
  @spec step_performance() :: [map()]
  def step_performance do
    events = get_all_step_events()

    events
    |> group_by_step()
    |> Enum.map(fn {step_name, step_events} ->
      durations = extract_durations(step_events)
      failures = count_failures(step_events)
      total = length(step_events)

      %{
        step: step_name,
        total_executions: total,
        failures: failures,
        failure_rate: if(total > 0, do: Float.round(failures / total, 2), else: 0.0),
        avg_duration_ms: if(Enum.empty?(durations), do: 0, else: round(Enum.sum(durations) / length(durations))),
        max_duration_ms: if(Enum.empty?(durations), do: 0, else: Enum.max(durations))
      }
    end)
    |> Enum.sort_by(& &1.failure_rate, :desc)
  end

  # ============================================================================
  # Tendencias Temporales
  # ============================================================================

  @doc """
  Calcula workflows por hora en las últimas 24 horas.

  Retorna una lista de 24 elementos con conteos por hora.
  """
  @spec hourly_trend() :: [map()]
  def hourly_trend do
    now = DateTime.utc_now()

    0..23
    |> Enum.map(fn hours_ago ->
      hour_start = DateTime.add(now, -hours_ago * 3600, :second)
      hour_end = DateTime.add(hour_start, 3600, :second)

      count = count_workflows_in_range(hour_start, hour_end)

      %{
        hour: hours_ago,
        label: format_hour(hour_start),
        count: count
      }
    end)
    |> Enum.reverse()
  end

  @doc """
  Calcula workflows por día en los últimos 7 días.
  """
  @spec daily_trend() :: [map()]
  def daily_trend do
    today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    0..6
    |> Enum.map(fn days_ago ->
      day_start = DateTime.add(today_start, -days_ago * 86400, :second)
      day_end = DateTime.add(day_start, 86400, :second)

      stats = count_workflows_by_status_in_range(day_start, day_end)

      %{
        day: days_ago,
        label: format_day(day_start),
        completed: stats.completed,
        failed: stats.failed,
        total: stats.completed + stats.failed
      }
    end)
    |> Enum.reverse()
  end

  @doc """
  Genera datos para un heatmap semanal estilo GitHub.

  Retorna 7 semanas × 7 días = 49 celdas con intensidad de actividad.
  """
  @spec weekly_heatmap() :: [map()]
  def weekly_heatmap do
    today = Date.utc_today()
    # 7 semanas hacia atrás, 7 días cada una
    days = for week <- 0..6, day <- 0..6 do
      days_ago = week * 7 + day
      date = Date.add(today, -days_ago)
      {week, day, date}
    end

    # Obtener conteos por fecha
    counts = get_daily_counts(49)

    days
    |> Enum.map(fn {week, day_of_week, date} ->
      count = Map.get(counts, date, 0)
      %{
        week: week,
        day: day_of_week,
        date: date,
        count: count,
        intensity: intensity_level(count, counts)
      }
    end)
    |> Enum.reverse()
  end

  @doc """
  Genera sparkline data para las últimas N horas.

  Útil para mini-gráficos en tarjetas KPI.
  """
  @spec sparkline_data(atom(), integer()) :: [integer()]
  def sparkline_data(metric, hours \\ 12) do
    now = DateTime.utc_now()

    0..(hours - 1)
    |> Enum.map(fn hours_ago ->
      hour_start = DateTime.add(now, -hours_ago * 3600, :second)
      hour_end = DateTime.add(hour_start, 3600, :second)

      case metric do
        :completed -> count_workflows_by_status_in_range(hour_start, hour_end).completed
        :failed -> count_workflows_by_status_in_range(hour_start, hour_end).failed
        :total -> count_workflows_in_range(hour_start, hour_end)
        _ -> 0
      end
    end)
    |> Enum.reverse()
  end

  defp get_daily_counts(days) do
    today = Date.utc_today()

    0..(days - 1)
    |> Enum.map(fn days_ago ->
      date = Date.add(today, -days_ago)
      day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      day_end = DateTime.add(day_start, 86400, :second)
      count = count_workflows_in_range(day_start, day_end)
      {date, count}
    end)
    |> Map.new()
  end

  defp intensity_level(count, counts) do
    max_count = counts |> Map.values() |> Enum.max(fn -> 1 end) |> max(1)
    cond do
      count == 0 -> 0
      count <= max_count * 0.25 -> 1
      count <= max_count * 0.5 -> 2
      count <= max_count * 0.75 -> 3
      true -> 4
    end
  end

  # ============================================================================
  # Métricas por Módulo
  # ============================================================================

  @doc """
  Calcula estadísticas agrupadas por módulo de workflow.
  """
  @spec by_module() :: [map()]
  def by_module do
    case WorkflowStore.list_workflows(limit: 1000) do
      {:ok, workflows} ->
        workflows
        |> Enum.group_by(&Map.get(&1, :workflow_module))
        |> Enum.map(fn {module, wfs} ->
          completed = Enum.count(wfs, &(Map.get(&1, :status) == :completed))
          failed = Enum.count(wfs, &(Map.get(&1, :status) == :failed))
          total = length(wfs)

          %{
            module: module_name(module),
            module_full: module,
            total: total,
            completed: completed,
            failed: failed,
            success_rate: if(total > 0, do: Float.round(completed / total, 2), else: 0.0)
          }
        end)
        |> Enum.sort_by(& &1.total, :desc)

      _ ->
        []
    end
  end

  # ============================================================================
  # Top Failures
  # ============================================================================

  @doc """
  Obtiene los workflows fallidos más recientes con detalles del error.
  """
  @spec recent_failures(keyword()) :: [map()]
  def recent_failures(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    case WorkflowStore.list_workflows(status: :failed, limit: limit) do
      {:ok, workflows} ->
        Enum.map(workflows, fn wf ->
          %{
            workflow_id: Map.get(wf, :workflow_id) || Map.get(wf, :id),
            module: module_name(Map.get(wf, :workflow_module)),
            error: truncate_error(Map.get(wf, :error)),
            failed_at: Map.get(wf, :completed_at) || Map.get(wf, :started_at),
            step_index: Map.get(wf, :current_step_index)
          }
        end)

      _ ->
        []
    end
  end

  # ============================================================================
  # Dashboard Aggregate
  # ============================================================================

  @doc """
  Retorna todas las métricas agregadas para el dashboard.

  ## Opciones

  - `:date_from` - Fecha inicial (DateTime)
  - `:date_to` - Fecha final (DateTime)
  - `:period` - Preset: :today, :week, :month, :all (default)

  Esta función es útil para cargar todo de una vez en el LiveView.
  """
  @spec dashboard_metrics(keyword()) :: map()
  def dashboard_metrics(opts \\ []) do
    {date_from, date_to} = resolve_date_range(opts)
    filter_opts = [date_from: date_from, date_to: date_to]

    %{
      summary: summary(filter_opts),
      performance: performance_metrics(),
      hourly_trend: hourly_trend(),
      daily_trend: daily_trend(),
      weekly_heatmap: weekly_heatmap(),
      sparklines: %{
        completed: sparkline_data(:completed, 12),
        failed: sparkline_data(:failed, 12),
        total: sparkline_data(:total, 12)
      },
      by_module: by_module(),
      step_performance: step_performance() |> Enum.take(10),
      recent_failures: recent_failures(limit: 5),
      is_sampled: is_sampled?(),
      sample_size: @max_sample_size,
      date_range: %{from: date_from, to: date_to}
    }
  end

  @doc """
  Exporta métricas en formato estructurado para JSON/CSV.

  Incluye un disclaimer si los datos están muestreados.
  """
  @spec export_metrics(keyword()) :: map()
  def export_metrics(opts \\ []) do
    metrics = dashboard_metrics(opts)
    is_sampled = metrics.is_sampled

    base_export = %{
      exported_at: DateTime.utc_now(),
      period: Keyword.get(opts, :period, :all),
      summary: metrics.summary,
      performance: metrics.performance,
      daily_trend: metrics.daily_trend,
      by_module: metrics.by_module,
      step_performance: step_performance(),
      recent_failures: recent_failures(limit: 20)
    }

    if is_sampled do
      Map.merge(base_export, %{
        _disclaimer: "⚠️ DATOS MUESTREADOS: Las métricas de este reporte se calcularon sobre una muestra representativa de #{@max_sample_size} registros para optimizar el rendimiento. Los valores pueden variar ligeramente respecto al total real.",
        _sample_info: %{
          is_sampled: true,
          sample_size: @max_sample_size,
          note: "Para datos completos, considere exportar en períodos más cortos o contacte al administrador."
        }
      })
    else
      Map.put(base_export, :_sample_info, %{is_sampled: false, sample_size: nil})
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp resolve_date_range(opts) do
    case Keyword.get(opts, :period) do
      :today ->
        today = Date.utc_today()
        {DateTime.new!(today, ~T[00:00:00], "Etc/UTC"), DateTime.utc_now()}

      :week ->
        now = DateTime.utc_now()
        {DateTime.add(now, -7, :day), now}

      :month ->
        now = DateTime.utc_now()
        {DateTime.add(now, -30, :day), now}

      _ ->
        {Keyword.get(opts, :date_from), Keyword.get(opts, :date_to)}
    end
  end

  defp is_sampled? do
    # Verificar si el último cálculo usó sampling
    Process.get(:analytics_sampled, false)
  end

  defp count_by_status_in_range(date_from, date_to) do
    case WorkflowStore.list_workflows(limit: @max_workflows_scan) do
      {:ok, workflows} ->
        filtered = filter_by_date_range(workflows, date_from, date_to)

        %{
          completed: Enum.count(filtered, &(Map.get(&1, :status) == :completed)),
          failed: Enum.count(filtered, &(Map.get(&1, :status) == :failed)),
          running: Enum.count(filtered, &(Map.get(&1, :status) == :running)),
          pending: Enum.count(filtered, &(Map.get(&1, :status) == :pending))
        }

      _ ->
        %{completed: 0, failed: 0, running: 0, pending: 0}
    end
  end

  defp filter_by_date_range(workflows, nil, nil), do: workflows
  defp filter_by_date_range(workflows, date_from, date_to) do
    Enum.filter(workflows, fn wf ->
      started = Map.get(wf, :started_at)
      in_range?(started, date_from, date_to)
    end)
  end

  defp in_range?(nil, _, _), do: false
  defp in_range?(dt, nil, nil), do: dt != nil
  defp in_range?(dt, from, nil), do: DateTime.compare(dt, from) in [:gt, :eq]
  defp in_range?(dt, nil, to), do: DateTime.compare(dt, to) == :lt
  defp in_range?(dt, from, to) do
    DateTime.compare(dt, from) in [:gt, :eq] && DateTime.compare(dt, to) == :lt
  end

  defp get_completed_durations do
    case WorkflowStore.list_workflows(status: :completed, limit: @max_workflows_scan) do
      {:ok, workflows} ->
        workflows
        |> Enum.filter(fn wf ->
          Map.get(wf, :started_at) && Map.get(wf, :completed_at)
        end)
        |> Enum.map(fn wf ->
          DateTime.diff(Map.get(wf, :completed_at), Map.get(wf, :started_at), :millisecond)
        end)
        |> Enum.filter(&(&1 > 0))

      _ ->
        []
    end
  end

  defp get_all_step_events do
    case WorkflowStore.list_workflows(limit: @max_workflows_scan) do
      {:ok, workflows} ->
        events =
          workflows
          |> Enum.flat_map(fn wf ->
            workflow_id = Map.get(wf, :workflow_id) || Map.get(wf, :id)
            case WorkflowStore.get_events(workflow_id) do
              {:ok, evts} ->
                evts
                |> Enum.filter(&(&1.event_type in [:step_completed, :step_failed]))

              _ ->
                []
            end
          end)

        # Aplicar sampling si hay demasiados eventos
        maybe_sample(events)

      _ ->
        []
    end
  end

  defp group_by_step(events) do
    events
    |> Enum.group_by(fn event ->
      data = event[:data] || event[:metadata] || %{}
      data[:step] || "unknown"
    end)
  end

  defp extract_durations(events) do
    events
    |> Enum.map(fn event ->
      data = event[:data] || event[:metadata] || %{}
      data[:duration_ms]
    end)
    |> Enum.filter(&is_integer/1)
  end

  defp count_failures(events) do
    Enum.count(events, &(&1.event_type == :step_failed))
  end

  defp count_workflows_in_range(start_dt, end_dt) do
    case WorkflowStore.list_workflows(limit: 1000) do
      {:ok, workflows} ->
        Enum.count(workflows, fn wf ->
          started = Map.get(wf, :started_at)
          started &&
            DateTime.compare(started, start_dt) in [:gt, :eq] &&
            DateTime.compare(started, end_dt) == :lt
        end)

      _ ->
        0
    end
  end

  defp count_workflows_by_status_in_range(start_dt, end_dt) do
    case WorkflowStore.list_workflows(limit: 1000) do
      {:ok, workflows} ->
        filtered =
          Enum.filter(workflows, fn wf ->
            started = Map.get(wf, :started_at)
            started &&
              DateTime.compare(started, start_dt) in [:gt, :eq] &&
              DateTime.compare(started, end_dt) == :lt
          end)

        %{
          completed: Enum.count(filtered, &(Map.get(&1, :status) == :completed)),
          failed: Enum.count(filtered, &(Map.get(&1, :status) == :failed))
        }

      _ ->
        %{completed: 0, failed: 0}
    end
  end

  defp percentile(sorted_list, p) when is_list(sorted_list) and length(sorted_list) > 0 do
    k = (p / 100) * (length(sorted_list) - 1)
    f = floor(k)
    c = ceil(k)

    if f == c do
      Enum.at(sorted_list, f)
    else
      lower = Enum.at(sorted_list, f)
      upper = Enum.at(sorted_list, c)
      round(lower + (upper - lower) * (k - f))
    end
  end

  defp percentile(_, _), do: 0

  defp format_hour(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:00")
  end

  defp format_day(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a %d")
  end

  defp module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
  end

  defp module_name(other), do: inspect(other)

  defp truncate_error(nil), do: "Unknown error"
  defp truncate_error(error) when is_binary(error) do
    if String.length(error) > 100 do
      String.slice(error, 0, 97) <> "..."
    else
      error
    end
  end
  defp truncate_error(error), do: inspect(error) |> truncate_error()
end
