defmodule BeamflowWeb.AnalyticsControllerTest do
  use BeamflowWeb.ConnCase

  alias Beamflow.Storage.WorkflowStore

  setup do
    # Limpiar datos de test previos
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
end
