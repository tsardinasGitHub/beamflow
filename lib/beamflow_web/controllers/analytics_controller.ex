defmodule BeamflowWeb.AnalyticsController do
  @moduledoc """
  API REST Controller para analytics de workflows.

  ## Endpoints

  - `GET /api/analytics/export` - Exporta métricas completas en JSON o CSV
  - `GET /api/analytics/summary` - Solo KPIs principales (ligero)
  - `GET /api/analytics/trends` - Datos para gráficos y visualizaciones

  ## Parámetros Comunes

  - `period` - Período: "today", "week", "month", "all" (default)
  - `date_from` - Fecha inicial ISO8601 (opcional)
  - `date_to` - Fecha final ISO8601 (opcional)

  ## Parámetros Específicos

  ### /export
  - `format` - Formato de salida: "json" (default) o "csv"

  ### /trends
  - `include` - Datos a incluir: "daily,hourly,heatmap,sparklines" (comma-separated)

  ## Ejemplos de Uso

      # Exportar todo en JSON
      curl "http://localhost:4000/api/analytics/export?period=week"

      # Solo KPIs (muy rápido)
      curl "http://localhost:4000/api/analytics/summary"

      # Datos para gráficos
      curl "http://localhost:4000/api/analytics/trends?include=daily,sparklines"

  ## Rate Limiting

  Límite: 60 requests por minuto por IP.
  Headers de respuesta: X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset
  """

  use BeamflowWeb, :controller

  alias Beamflow.Analytics.WorkflowAnalytics

  @doc """
  Exporta métricas de analytics.

  Soporta filtrado por período o rango de fechas personalizado.
  """
  def export(conn, params) do
    format = Map.get(params, "format", "json")
    opts = build_export_opts(params)

    data = WorkflowAnalytics.export_metrics(opts)

    case format do
      "csv" ->
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header("content-disposition", "attachment; filename=\"beamflow_analytics_#{Date.utc_today()}.csv\"")
        |> send_resp(200, format_csv(data))

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("content-disposition", "attachment; filename=\"beamflow_analytics_#{Date.utc_today()}.json\"")
        |> json(data)
    end
  end

  defp build_export_opts(params) do
    opts = []

    # Period preset
    opts = case Map.get(params, "period") do
      "today" -> Keyword.put(opts, :period, :today)
      "week" -> Keyword.put(opts, :period, :week)
      "month" -> Keyword.put(opts, :period, :month)
      _ -> opts
    end

    # Custom date range (overrides period)
    opts = case {Map.get(params, "date_from"), Map.get(params, "date_to")} do
      {nil, nil} -> opts
      {from_str, to_str} ->
        with {:ok, from_date} <- parse_date(from_str),
             {:ok, to_date} <- parse_date(to_str) do
          opts
          |> Keyword.put(:date_from, DateTime.new!(from_date, ~T[00:00:00]))
          |> Keyword.put(:date_to, DateTime.new!(to_date, ~T[23:59:59]))
        else
          _ -> opts
        end
    end

    opts
  end

  defp parse_date(nil), do: {:ok, Date.utc_today()}
  defp parse_date(date_str) when is_binary(date_str), do: Date.from_iso8601(date_str)

  defp format_csv(data) do
    # Disclaimer header si hay sampling
    disclaimer = if Map.get(data, :_disclaimer) do
      "# #{data._disclaimer}\n# Muestra: #{data._sample_info.sample_size} registros\n\n"
    else
      "# Beamflow Analytics Export\n# Generado: #{DateTime.utc_now()}\n\n"
    end

    # Summary section
    summary_csv = "=== SUMMARY ===\nMetric,Value\n" <>
      Enum.map_join(data.summary, "\n", fn {k, v} -> "#{k},#{v}" end)

    # Performance section
    perf_csv = "\n\n=== PERFORMANCE ===\nMetric,Value (ms)\n" <>
      Enum.map_join(data.performance, "\n", fn {k, v} -> "#{k},#{v}" end)

    # Daily trend section
    daily_csv = "\n\n=== DAILY TREND ===\nDay,Completed,Failed,Total\n" <>
      Enum.map_join(data.daily_trend, "\n", fn day ->
        "#{day.label},#{day.completed},#{day.failed},#{day.total}"
      end)

    # By module section
    module_csv = "\n\n=== BY MODULE ===\nModule,Total,Completed,Failed,Success Rate\n" <>
      Enum.map_join(data.by_module, "\n", fn m ->
        "#{m.module},#{m.total},#{m.completed},#{m.failed},#{m.success_rate}"
      end)

    disclaimer <> summary_csv <> perf_csv <> daily_csv <> module_csv
  end

  # ============================================================================
  # Summary Endpoint - Solo KPIs (ligero)
  # ============================================================================

  @doc """
  Retorna solo los KPIs principales.

  Endpoint optimizado para dashboards externos que solo necesitan métricas clave.
  Mucho más rápido que /export porque no calcula tendencias ni datos por módulo.
  """
  @spec summary(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def summary(conn, params) do
    opts = build_export_opts(params)
    metrics = WorkflowAnalytics.dashboard_metrics(opts)
    summary_data = metrics.summary
    performance = metrics.performance

    summary = %{
      total_workflows: summary_data.total,
      completed: summary_data.completed,
      failed: summary_data.failed,
      in_progress: summary_data.running,
      pending: summary_data.pending,
      success_rate: summary_data.success_rate,
      failure_rate: summary_data.failure_rate,
      avg_duration_ms: performance.avg_duration_ms,
      period: period_from_opts(opts),
      generated_at: DateTime.utc_now()
    }

    json(conn, summary)
  end

  # ============================================================================
  # Trends Endpoint - Datos para gráficos
  # ============================================================================

  @doc """
  Retorna datos optimizados para visualizaciones y gráficos.

  Parámetro `include` permite seleccionar qué datos incluir:
  - `daily` - Tendencia diaria (últimos 7 días)
  - `hourly` - Distribución por hora del día
  - `heatmap` - Datos para heatmap semanal
  - `sparklines` - Mini gráficos para KPIs

  Ejemplo: `?include=daily,sparklines`
  """
  @spec trends(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def trends(conn, params) do
    opts = build_export_opts(params)
    include = parse_include_param(Map.get(params, "include", "daily,sparklines"))

    trends = %{
      period: period_from_opts(opts),
      generated_at: DateTime.utc_now()
    }

    trends = if "daily" in include do
      daily = WorkflowAnalytics.daily_trend()
      Map.put(trends, :daily, format_daily_trend(daily))
    else
      trends
    end

    trends = if "hourly" in include do
      hourly = WorkflowAnalytics.hourly_distribution()
      Map.put(trends, :hourly, hourly)
    else
      trends
    end

    trends = if "heatmap" in include do
      heatmap = WorkflowAnalytics.weekly_heatmap()
      Map.put(trends, :heatmap, format_heatmap(heatmap))
    else
      trends
    end

    trends = if "sparklines" in include do
      sparklines = WorkflowAnalytics.adaptive_sparklines(opts)
      Map.put(trends, :sparklines, sparklines)
    else
      trends
    end

    json(conn, trends)
  end

  # ============================================================================
  # Health Check Endpoint
  # ============================================================================

  @doc """
  Health check simple para monitoreo.
  No cuenta contra el rate limit.
  """
  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "beamflow_analytics",
      timestamp: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp parse_include_param(include_str) when is_binary(include_str) do
    include_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp period_from_opts(opts) do
    cond do
      opts[:date_from] && opts[:date_to] ->
        %{
          type: "custom",
          from: opts[:date_from],
          to: opts[:date_to]
        }

      opts[:period] ->
        %{type: to_string(opts[:period])}

      true ->
        %{type: "all"}
    end
  end

  defp format_daily_trend(daily) do
    Enum.map(daily, fn day ->
      %{
        date: day.label,
        completed: day.completed,
        failed: day.failed,
        total: day.total,
        success_rate: if(day.total > 0, do: Float.round(day.completed / day.total * 100, 1), else: 0.0)
      }
    end)
  end

  defp format_heatmap(heatmap) do
    day_names = ["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"]

    Enum.map(heatmap, fn day ->
      day_of_week = day.day
      %{
        date: to_string(day.date),
        week: day.week,
        day_of_week: day_of_week,
        day_name: Enum.at(day_names, day_of_week, ""),
        count: day.count,
        level: day.intensity
      }
    end)
  end
end
