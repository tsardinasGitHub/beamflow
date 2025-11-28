defmodule BeamflowWeb.AnalyticsController do
  @moduledoc """
  API REST Controller para exportación programática de analytics.

  ## Endpoints

  - `GET /api/analytics/export` - Exporta métricas en JSON o CSV

  ## Parámetros

  - `format` - Formato de salida: "json" (default) o "csv"
  - `period` - Período: "today", "week", "month", "all" (default)
  - `date_from` - Fecha inicial ISO8601 (opcional)
  - `date_to` - Fecha final ISO8601 (opcional)

  ## Ejemplo de Uso

      curl "http://localhost:4000/api/analytics/export?format=json&period=week"

      curl "http://localhost:4000/api/analytics/export?format=csv&date_from=2025-11-01&date_to=2025-11-28"

  ## Rate Limiting

  Se recomienda implementar rate limiting en producción para evitar abuso.
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
end
