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

  # ============================================================================
  # Resumen General
  # ============================================================================

  @doc """
  Calcula un resumen general de todos los workflows.

  Retorna conteos por estado y tasas de éxito/fallo.
  """
  @spec summary() :: map()
  def summary do
    stats = WorkflowStore.count_by_status()

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
    now = DateTime.utc_now()
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

  Esta función es útil para cargar todo de una vez en el LiveView.
  """
  @spec dashboard_metrics() :: map()
  def dashboard_metrics do
    %{
      summary: summary(),
      performance: performance_metrics(),
      hourly_trend: hourly_trend(),
      daily_trend: daily_trend(),
      by_module: by_module(),
      step_performance: step_performance() |> Enum.take(10),
      recent_failures: recent_failures(limit: 5)
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_completed_durations do
    case WorkflowStore.list_workflows(status: :completed, limit: 500) do
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
    case WorkflowStore.list_workflows(limit: 200) do
      {:ok, workflows} ->
        workflows
        |> Enum.flat_map(fn wf ->
          workflow_id = Map.get(wf, :workflow_id) || Map.get(wf, :id)
          case WorkflowStore.get_events(workflow_id) do
            {:ok, events} ->
              events
              |> Enum.filter(&(&1.event_type in [:step_completed, :step_failed]))

            _ ->
              []
          end
        end)

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
