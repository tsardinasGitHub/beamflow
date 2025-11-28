defmodule BeamflowWeb.AnalyticsControllerTest do
  use BeamflowWeb.ConnCase

  alias Beamflow.Storage.WorkflowStore

  setup do
    # Desactivar rate limiting para tests
    Application.put_env(:beamflow, :rate_limit_enabled, false)
    BeamflowWeb.Plugs.RateLimiter.clear_all()

    on_exit(fn ->
      Application.put_env(:beamflow, :rate_limit_enabled, true)
    end)

    :ok
  end

  describe "GET /api/analytics/export" do
    test "returns JSON by default", %{conn: conn} do
      conn = get(conn, "/api/analytics/export")

      assert response_content_type(conn, :json)
      assert json_response(conn, 200)
    end

    test "returns JSON with format=json", %{conn: conn} do
      conn = get(conn, "/api/analytics/export", format: "json")

      assert response_content_type(conn, :json)
      response = json_response(conn, 200)

      assert Map.has_key?(response, "summary")
      assert Map.has_key?(response, "performance")
      assert Map.has_key?(response, "exported_at")
    end

    test "returns CSV with format=csv", %{conn: conn} do
      conn = get(conn, "/api/analytics/export", format: "csv")

      assert response_content_type(conn, :csv) =~ "text/csv"
      body = response(conn, 200)

      assert body =~ "SUMMARY"
      assert body =~ "PERFORMANCE"
    end

    test "includes content-disposition header for download", %{conn: conn} do
      conn = get(conn, "/api/analytics/export", format: "json")

      assert get_resp_header(conn, "content-disposition") != []
    end

    test "supports period=today filter", %{conn: conn} do
      conn = get(conn, "/api/analytics/export", period: "today")

      response = json_response(conn, 200)
      assert Map.has_key?(response, "summary")
    end

    test "supports period=week filter", %{conn: conn} do
      conn = get(conn, "/api/analytics/export", period: "week")

      response = json_response(conn, 200)
      assert Map.has_key?(response, "summary")
    end

    test "supports period=month filter", %{conn: conn} do
      conn = get(conn, "/api/analytics/export", period: "month")

      response = json_response(conn, 200)
      assert Map.has_key?(response, "summary")
    end

    test "supports custom date range", %{conn: conn} do
      conn = get(conn, "/api/analytics/export",
        date_from: "2025-11-01",
        date_to: "2025-11-28"
      )

      response = json_response(conn, 200)
      assert Map.has_key?(response, "summary")
    end

    test "includes sample_info in response", %{conn: conn} do
      conn = get(conn, "/api/analytics/export")

      response = json_response(conn, 200)
      assert Map.has_key?(response, "_sample_info")
    end
  end

  describe "GET /api/analytics/summary" do
    test "returns only KPIs", %{conn: conn} do
      conn = get(conn, "/api/analytics/summary")

      response = json_response(conn, 200)

      assert Map.has_key?(response, "total_workflows")
      assert Map.has_key?(response, "completed")
      assert Map.has_key?(response, "failed")
      assert Map.has_key?(response, "success_rate")
      assert Map.has_key?(response, "generated_at")
      # No debe incluir datos pesados
      refute Map.has_key?(response, "daily_trend")
      refute Map.has_key?(response, "by_module")
    end

    test "supports period filter", %{conn: conn} do
      conn = get(conn, "/api/analytics/summary", period: "week")

      response = json_response(conn, 200)
      assert response["period"]["type"] == "week"
    end

    test "is faster than export", %{conn: conn} do
      # Summary debería ser más rápido
      {summary_time, _} = :timer.tc(fn -> get(conn, "/api/analytics/summary") end)
      {export_time, _} = :timer.tc(fn -> get(conn, "/api/analytics/export") end)

      # Summary debería tardar menos (o similar)
      assert summary_time <= export_time * 2
    end
  end

  describe "GET /api/analytics/trends" do
    test "returns daily trends by default", %{conn: conn} do
      conn = get(conn, "/api/analytics/trends")

      response = json_response(conn, 200)

      assert Map.has_key?(response, "daily")
      assert Map.has_key?(response, "sparklines")
      assert Map.has_key?(response, "generated_at")
    end

    test "supports include parameter", %{conn: conn} do
      conn = get(conn, "/api/analytics/trends", include: "daily,heatmap")

      response = json_response(conn, 200)

      assert Map.has_key?(response, "daily")
      assert Map.has_key?(response, "heatmap")
    end

    test "returns hourly distribution when requested", %{conn: conn} do
      conn = get(conn, "/api/analytics/trends", include: "hourly")

      response = json_response(conn, 200)

      assert Map.has_key?(response, "hourly")
      assert is_list(response["hourly"])
      # Debería haber 24 horas
      assert length(response["hourly"]) == 24
    end

    test "returns heatmap data when requested", %{conn: conn} do
      conn = get(conn, "/api/analytics/trends", include: "heatmap")

      response = json_response(conn, 200)

      assert Map.has_key?(response, "heatmap")
      heatmap = response["heatmap"]
      assert is_list(heatmap)
      assert length(heatmap) == 49  # 7 semanas × 7 días
    end

    test "returns sparklines when requested", %{conn: conn} do
      conn = get(conn, "/api/analytics/trends", include: "sparklines")

      response = json_response(conn, 200)

      assert Map.has_key?(response, "sparklines")
      sparklines = response["sparklines"]
      assert Map.has_key?(sparklines, "completed")
      assert Map.has_key?(sparklines, "failed")
      assert Map.has_key?(sparklines, "total")
    end
  end

  describe "GET /api/health" do
    test "returns OK status", %{conn: conn} do
      conn = get(conn, "/api/health")

      response = json_response(conn, 200)

      assert response["status"] == "ok"
      assert response["service"] == "beamflow_analytics"
      assert Map.has_key?(response, "timestamp")
    end
  end

  describe "CSV format" do
    test "includes all sections", %{conn: conn} do
      conn = get(conn, "/api/analytics/export", format: "csv")
      body = response(conn, 200)

      assert body =~ "=== SUMMARY ==="
      assert body =~ "=== PERFORMANCE ==="
      assert body =~ "=== DAILY TREND ==="
      assert body =~ "=== BY MODULE ==="
    end
  end

  describe "Rate Limiting" do
    setup do
      # Activar rate limiting para estos tests
      Application.put_env(:beamflow, :rate_limit_enabled, true)
      BeamflowWeb.Plugs.RateLimiter.clear_all()

      on_exit(fn ->
        Application.put_env(:beamflow, :rate_limit_enabled, false)
        BeamflowWeb.Plugs.RateLimiter.clear_all()
      end)

      :ok
    end

    test "includes rate limit headers", %{conn: conn} do
      conn = get(conn, "/api/analytics/summary")

      assert get_resp_header(conn, "x-ratelimit-limit") != []
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
      assert get_resp_header(conn, "x-ratelimit-reset") != []
    end

    test "decrements remaining count", %{conn: conn} do
      conn1 = get(conn, "/api/analytics/summary")
      [remaining1] = get_resp_header(conn1, "x-ratelimit-remaining")

      conn2 = get(conn, "/api/analytics/summary")
      [remaining2] = get_resp_header(conn2, "x-ratelimit-remaining")

      assert String.to_integer(remaining2) < String.to_integer(remaining1)
    end

    test "returns 429 when limit exceeded", %{conn: _conn} do
      # Test del rate limiter directamente usando el plug

      Application.put_env(:beamflow, :rate_limit_enabled, true)
      BeamflowWeb.Plugs.RateLimiter.clear_all()

      opts = BeamflowWeb.Plugs.RateLimiter.init(max_requests: 3, window_ms: 60_000)

      # Crear un conn con IP conocida
      base_conn = Phoenix.ConnTest.build_conn()
      |> Map.put(:remote_ip, {192, 168, 1, 100})

      # Primeros 3 requests deben pasar (1, 2, 3)
      conn1 = BeamflowWeb.Plugs.RateLimiter.call(base_conn, opts)
      assert [remaining1] = Plug.Conn.get_resp_header(conn1, "x-ratelimit-remaining")
      refute conn1.halted, "Request 1 no debería ser bloqueado"

      conn2 = BeamflowWeb.Plugs.RateLimiter.call(base_conn, opts)
      assert [remaining2] = Plug.Conn.get_resp_header(conn2, "x-ratelimit-remaining")
      refute conn2.halted, "Request 2 no debería ser bloqueado"

      conn3 = BeamflowWeb.Plugs.RateLimiter.call(base_conn, opts)
      assert [remaining3] = Plug.Conn.get_resp_header(conn3, "x-ratelimit-remaining")
      refute conn3.halted, "Request 3 no debería ser bloqueado"

      # El 4to request debe ser rechazado
      conn4 = BeamflowWeb.Plugs.RateLimiter.call(base_conn, opts)

      # Verificar que el 4to request fue rechazado
      assert conn4.halted, "Request 4 debería ser bloqueado. Stats: #{inspect(BeamflowWeb.Plugs.RateLimiter.stats())}"
      assert conn4.status == 429
    end

    test "health endpoint bypasses rate limiting", %{conn: conn} do
      # Hacer muchos requests al health
      results = for _ <- 1..100 do
        conn = get(conn, "/api/health")
        conn.status
      end

      # Todos deben ser 200
      assert Enum.all?(results, &(&1 == 200))
    end
  end
end
