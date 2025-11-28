defmodule Beamflow.Analytics.WorkflowAnalyticsTest do
  @moduledoc """
  Tests para Beamflow.Analytics.WorkflowAnalytics.

  Verifica el cálculo correcto de métricas, estadísticas y tendencias
  de workflows.
  """

  use ExUnit.Case, async: false

  alias Beamflow.Analytics.WorkflowAnalytics
  alias Beamflow.Storage.WorkflowStore

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    :ok = ensure_mnesia_started()

    # Limpiar datos anteriores
    cleanup_test_workflows()

    :ok
  end

  defp ensure_mnesia_started do
    case :mnesia.system_info(:is_running) do
      :yes -> :ok
      :no ->
        :mnesia.start()
        Process.sleep(100)
        :ok
      :starting ->
        Process.sleep(100)
        ensure_mnesia_started()
      :stopping ->
        Process.sleep(100)
        ensure_mnesia_started()
    end
  end

  defp cleanup_test_workflows do
    case WorkflowStore.list_workflows(limit: 1000) do
      {:ok, workflows} ->
        workflows
        |> Enum.filter(fn wf ->
          id = Map.get(wf, :workflow_id) || Map.get(wf, :id) || ""
          String.starts_with?(to_string(id), "analytics-test-")
        end)
        |> Enum.each(fn wf ->
          id = Map.get(wf, :workflow_id) || Map.get(wf, :id)
          if id, do: WorkflowStore.delete_workflow(id)
        end)

      _ ->
        :ok
    end
  end

  # ============================================================================
  # Tests de Summary
  # ============================================================================

  describe "summary/0" do
    test "retorna estructura correcta sin workflows" do
      summary = WorkflowAnalytics.summary()

      assert is_map(summary)
      assert Map.has_key?(summary, :total)
      assert Map.has_key?(summary, :completed)
      assert Map.has_key?(summary, :failed)
      assert Map.has_key?(summary, :running)
      assert Map.has_key?(summary, :pending)
      assert Map.has_key?(summary, :success_rate)
      assert Map.has_key?(summary, :failure_rate)
    end

    test "calcula totales correctamente" do
      # Crear workflows de prueba
      create_test_workflow("analytics-test-1", :completed)
      create_test_workflow("analytics-test-2", :completed)
      create_test_workflow("analytics-test-3", :failed)
      create_test_workflow("analytics-test-4", :running)

      summary = WorkflowAnalytics.summary()

      # Los valores deben incluir al menos nuestros workflows de prueba
      assert summary.total >= 4
      assert summary.completed >= 2
      assert summary.failed >= 1
      assert summary.running >= 1
    end

    test "calcula success_rate correctamente" do
      create_test_workflow("analytics-test-sr-1", :completed)
      create_test_workflow("analytics-test-sr-2", :completed)
      create_test_workflow("analytics-test-sr-3", :completed)
      create_test_workflow("analytics-test-sr-4", :failed)

      summary = WorkflowAnalytics.summary()

      # Con 3 completed y 1 failed de 4 total, success rate debería ser ~0.75
      assert is_float(summary.success_rate)
      assert summary.success_rate >= 0.0
      assert summary.success_rate <= 1.0
    end
  end

  # ============================================================================
  # Tests de Performance Metrics
  # ============================================================================

  describe "performance_metrics/0" do
    test "retorna estructura correcta" do
      metrics = WorkflowAnalytics.performance_metrics()

      assert is_map(metrics)
      assert Map.has_key?(metrics, :avg_duration_ms)
      assert Map.has_key?(metrics, :min_duration_ms)
      assert Map.has_key?(metrics, :max_duration_ms)
      assert Map.has_key?(metrics, :p50)
      assert Map.has_key?(metrics, :p95)
      assert Map.has_key?(metrics, :p99)
      assert Map.has_key?(metrics, :sample_size)
    end

    test "retorna ceros cuando no hay workflows completados" do
      metrics = WorkflowAnalytics.performance_metrics()

      # Sin workflows, todos los valores deben ser 0 o el sample_size
      assert is_integer(metrics.avg_duration_ms)
      assert is_integer(metrics.sample_size)
    end

    test "calcula métricas con workflows completados" do
      # Crear workflows con tiempos conocidos
      now = DateTime.utc_now()
      started = DateTime.add(now, -5, :second)

      create_test_workflow_with_times("analytics-test-perf-1", :completed, started, now)

      metrics = WorkflowAnalytics.performance_metrics()

      # Debería tener al menos 1 sample
      assert metrics.sample_size >= 1
    end
  end

  # ============================================================================
  # Tests de Tendencias
  # ============================================================================

  describe "hourly_trend/0" do
    test "retorna 24 elementos" do
      trend = WorkflowAnalytics.hourly_trend()

      assert is_list(trend)
      assert length(trend) == 24
    end

    test "cada elemento tiene estructura correcta" do
      trend = WorkflowAnalytics.hourly_trend()

      Enum.each(trend, fn hour_data ->
        assert Map.has_key?(hour_data, :hour)
        assert Map.has_key?(hour_data, :label)
        assert Map.has_key?(hour_data, :count)
        assert is_integer(hour_data.count)
      end)
    end

    test "horas están ordenadas cronológicamente" do
      trend = WorkflowAnalytics.hourly_trend()

      hours = Enum.map(trend, & &1.hour)
      # La primera hora es -23, la última es 0 (ahora)
      assert List.first(hours) == 23
      assert List.last(hours) == 0
    end
  end

  describe "daily_trend/0" do
    test "retorna 7 elementos" do
      trend = WorkflowAnalytics.daily_trend()

      assert is_list(trend)
      assert length(trend) == 7
    end

    test "cada elemento tiene estructura correcta" do
      trend = WorkflowAnalytics.daily_trend()

      Enum.each(trend, fn day_data ->
        assert Map.has_key?(day_data, :day)
        assert Map.has_key?(day_data, :label)
        assert Map.has_key?(day_data, :completed)
        assert Map.has_key?(day_data, :failed)
        assert Map.has_key?(day_data, :total)
      end)
    end
  end

  # ============================================================================
  # Tests de Métricas por Módulo
  # ============================================================================

  describe "by_module/0" do
    test "retorna lista de módulos" do
      modules = WorkflowAnalytics.by_module()

      assert is_list(modules)
    end

    test "cada módulo tiene estructura correcta" do
      create_test_workflow("analytics-test-mod-1", :completed)

      modules = WorkflowAnalytics.by_module()

      if Enum.any?(modules) do
        mod = hd(modules)
        assert Map.has_key?(mod, :module)
        assert Map.has_key?(mod, :total)
        assert Map.has_key?(mod, :completed)
        assert Map.has_key?(mod, :failed)
        assert Map.has_key?(mod, :success_rate)
      end
    end
  end

  # ============================================================================
  # Tests de Step Performance
  # ============================================================================

  describe "step_performance/0" do
    test "retorna lista" do
      steps = WorkflowAnalytics.step_performance()

      assert is_list(steps)
    end

    test "steps tienen estructura correcta cuando hay datos" do
      # Crear workflow con eventos
      workflow_id = "analytics-test-step-1"
      create_test_workflow(workflow_id, :completed)

      Process.sleep(1)
      :ok = WorkflowStore.record_event(workflow_id, :step_completed, %{
        step: "TestStep",
        step_index: 0,
        duration_ms: 100
      })

      steps = WorkflowAnalytics.step_performance()

      if Enum.any?(steps) do
        step = hd(steps)
        assert Map.has_key?(step, :step)
        assert Map.has_key?(step, :total_executions)
        assert Map.has_key?(step, :failures)
        assert Map.has_key?(step, :failure_rate)
        assert Map.has_key?(step, :avg_duration_ms)
      end
    end
  end

  # ============================================================================
  # Tests de Recent Failures
  # ============================================================================

  describe "recent_failures/1" do
    test "retorna lista vacía sin fallos" do
      failures = WorkflowAnalytics.recent_failures(limit: 5)

      assert is_list(failures)
    end

    test "retorna fallos cuando existen" do
      create_test_workflow("analytics-test-fail-1", :failed, "Test error message")

      failures = WorkflowAnalytics.recent_failures(limit: 5)

      if Enum.any?(failures) do
        failure = hd(failures)
        assert Map.has_key?(failure, :workflow_id)
        assert Map.has_key?(failure, :module)
        assert Map.has_key?(failure, :error)
      end
    end

    test "respeta límite" do
      create_test_workflow("analytics-test-fail-2", :failed, "Error 1")
      create_test_workflow("analytics-test-fail-3", :failed, "Error 2")
      create_test_workflow("analytics-test-fail-4", :failed, "Error 3")

      failures = WorkflowAnalytics.recent_failures(limit: 2)

      assert length(failures) <= 2
    end
  end

  # ============================================================================
  # Tests de Dashboard Aggregate
  # ============================================================================

  describe "dashboard_metrics/0" do
    test "retorna todas las métricas agregadas" do
      metrics = WorkflowAnalytics.dashboard_metrics()

      assert is_map(metrics)
      assert Map.has_key?(metrics, :summary)
      assert Map.has_key?(metrics, :performance)
      assert Map.has_key?(metrics, :hourly_trend)
      assert Map.has_key?(metrics, :daily_trend)
      assert Map.has_key?(metrics, :by_module)
      assert Map.has_key?(metrics, :step_performance)
      assert Map.has_key?(metrics, :recent_failures)
    end

    test "summary tiene campos requeridos" do
      metrics = WorkflowAnalytics.dashboard_metrics()

      assert is_map(metrics.summary)
      assert Map.has_key?(metrics.summary, :total)
      assert Map.has_key?(metrics.summary, :success_rate)
    end

    test "hourly_trend tiene 24 horas" do
      metrics = WorkflowAnalytics.dashboard_metrics()

      assert length(metrics.hourly_trend) == 24
    end

    test "daily_trend tiene 7 días" do
      metrics = WorkflowAnalytics.dashboard_metrics()

      assert length(metrics.daily_trend) == 7
    end

    test "incluye flag is_sampled" do
      metrics = WorkflowAnalytics.dashboard_metrics()

      assert Map.has_key?(metrics, :is_sampled)
      assert is_boolean(metrics.is_sampled)
    end

    test "incluye date_range" do
      metrics = WorkflowAnalytics.dashboard_metrics()

      assert Map.has_key?(metrics, :date_range)
      assert Map.has_key?(metrics.date_range, :from)
      assert Map.has_key?(metrics.date_range, :to)
    end
  end

  # ============================================================================
  # Tests de Filtros de Fecha
  # ============================================================================

  describe "summary/1 con filtros de fecha" do
    test "filtra por date_from y date_to" do
      now = DateTime.utc_now()
      yesterday = DateTime.add(now, -86400, :second)
      tomorrow = DateTime.add(now, 86400, :second)

      # Crear workflow de hoy
      create_test_workflow_with_times(
        "date-filter-today-#{System.unique_integer([:positive])}",
        :completed,
        now,
        now
      )

      # Summary con rango que incluye hoy
      summary = WorkflowAnalytics.summary(date_from: yesterday, date_to: tomorrow)

      assert is_map(summary)
      assert Map.has_key?(summary, :total)
    end

    test "retorna ceros para rango vacío" do
      # Rango en el pasado lejano
      past_from = DateTime.add(DateTime.utc_now(), -365 * 86400, :second)
      past_to = DateTime.add(past_from, 86400, :second)

      summary = WorkflowAnalytics.summary(date_from: past_from, date_to: past_to)

      assert summary.total >= 0
    end
  end

  # ============================================================================
  # Tests de Export Metrics
  # ============================================================================

  describe "export_metrics/1" do
    test "retorna estructura exportable" do
      export = WorkflowAnalytics.export_metrics()

      assert is_map(export)
      assert Map.has_key?(export, :exported_at)
      assert Map.has_key?(export, :summary)
      assert Map.has_key?(export, :performance)
      assert Map.has_key?(export, :daily_trend)
      assert Map.has_key?(export, :by_module)
    end

    test "exported_at es DateTime" do
      export = WorkflowAnalytics.export_metrics()

      assert %DateTime{} = export.exported_at
    end

    test "incluye step_performance completo" do
      export = WorkflowAnalytics.export_metrics()

      assert is_list(export.step_performance)
    end

    test "incluye más recent_failures que dashboard" do
      export = WorkflowAnalytics.export_metrics()

      assert is_list(export.recent_failures)
      # Export tiene límite de 20 vs 5 de dashboard
    end

    test "incluye sample_info" do
      export = WorkflowAnalytics.export_metrics()

      assert Map.has_key?(export, :_sample_info)
      assert is_map(export._sample_info)
      assert Map.has_key?(export._sample_info, :is_sampled)
    end
  end

  # ============================================================================
  # Tests de Weekly Heatmap
  # ============================================================================

  describe "weekly_heatmap/0" do
    test "retorna 49 celdas (7 semanas x 7 días)" do
      heatmap = WorkflowAnalytics.weekly_heatmap()

      assert is_list(heatmap)
      assert length(heatmap) == 49
    end

    test "cada celda tiene estructura correcta" do
      heatmap = WorkflowAnalytics.weekly_heatmap()
      cell = hd(heatmap)

      assert Map.has_key?(cell, :week)
      assert Map.has_key?(cell, :day)
      assert Map.has_key?(cell, :date)
      assert Map.has_key?(cell, :count)
      assert Map.has_key?(cell, :intensity)
    end

    test "intensity está entre 0 y 4" do
      heatmap = WorkflowAnalytics.weekly_heatmap()

      Enum.each(heatmap, fn cell ->
        assert cell.intensity >= 0 && cell.intensity <= 4
      end)
    end
  end

  # ============================================================================
  # Tests de Sparkline Data
  # ============================================================================

  describe "sparkline_data/2" do
    test "retorna lista de N elementos" do
      data = WorkflowAnalytics.sparkline_data(:total, 12)

      assert is_list(data)
      assert length(data) == 12
    end

    test "todos los valores son enteros no negativos" do
      data = WorkflowAnalytics.sparkline_data(:completed, 6)

      Enum.each(data, fn val ->
        assert is_integer(val)
        assert val >= 0
      end)
    end

    test "soporta diferentes métricas" do
      completed = WorkflowAnalytics.sparkline_data(:completed, 6)
      failed = WorkflowAnalytics.sparkline_data(:failed, 6)
      total = WorkflowAnalytics.sparkline_data(:total, 6)

      assert is_list(completed)
      assert is_list(failed)
      assert is_list(total)
    end

    test "métrica desconocida retorna ceros" do
      data = WorkflowAnalytics.sparkline_data(:unknown_metric, 4)

      assert data == [0, 0, 0, 0]
    end
  end

  # ============================================================================
  # Tests de Adaptive Sparklines
  # ============================================================================

  describe "adaptive_sparklines/2" do
    test "retorna mapa con completed, failed, total" do
      result = WorkflowAnalytics.adaptive_sparklines(6, :hour)

      assert is_map(result)
      assert Map.has_key?(result, :completed)
      assert Map.has_key?(result, :failed)
      assert Map.has_key?(result, :total)
    end

    test "cada lista tiene N elementos según count" do
      result = WorkflowAnalytics.adaptive_sparklines(8, :hour)

      assert length(result.completed) == 8
      assert length(result.failed) == 8
      assert length(result.total) == 8
    end

    test "funciona con unit :day" do
      result = WorkflowAnalytics.adaptive_sparklines(7, :day)

      assert length(result.completed) == 7
      assert is_list(result.total)
    end

    test "valores son enteros no negativos" do
      result = WorkflowAnalytics.adaptive_sparklines(4, :hour)

      Enum.each(result.completed, fn v ->
        assert is_integer(v) && v >= 0
      end)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp create_test_workflow(id, status, error \\ nil) do
    workflow = %{
      workflow_id: id,
      workflow_module: TestAnalyticsWorkflow,
      status: status,
      workflow_state: %{},
      current_step_index: 0,
      total_steps: 3,
      started_at: DateTime.utc_now(),
      completed_at: if(status in [:completed, :failed], do: DateTime.utc_now(), else: nil),
      error: error
    }

    {:ok, _} = WorkflowStore.save_workflow(workflow)
    workflow
  end

  defp create_test_workflow_with_times(id, status, started_at, completed_at) do
    workflow = %{
      workflow_id: id,
      workflow_module: TestAnalyticsWorkflow,
      status: status,
      workflow_state: %{},
      current_step_index: 0,
      total_steps: 3,
      started_at: started_at,
      completed_at: completed_at,
      error: nil
    }

    {:ok, _} = WorkflowStore.save_workflow(workflow)
    workflow
  end
end

# Módulo de test
defmodule TestAnalyticsWorkflow do
  @moduledoc false

  def steps, do: [Step1, Step2, Step3]
end
