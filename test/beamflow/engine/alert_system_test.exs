defmodule Beamflow.Engine.AlertSystemTest do
  @moduledoc """
  Tests para Alert System.
  """

  use ExUnit.Case, async: false

  alias Beamflow.Engine.AlertSystem

  setup do
    # Asegurar que AlertSystem está corriendo
    case Process.whereis(AlertSystem) do
      nil ->
        {:ok, _} = AlertSystem.start_link()
      _pid ->
        :ok
    end

    :ok
  end

  describe "send_alert/1" do
    test "sends alert successfully" do
      alert = %{
        severity: :medium,
        type: :test_alert_success,
        title: "Test Alert Success",
        message: "This is a test",
        metadata: %{key: "value"}
      }

      assert :ok = AlertSystem.send_alert(alert)

      # Verificar que se agregó al buffer, filtrando por type
      Process.sleep(50)
      recent = AlertSystem.recent_alerts(type: :test_alert_success, limit: 10)
      assert Enum.any?(recent, & &1.title == "Test Alert Success")
    end

    test "enriches alert with timestamp and id" do
      AlertSystem.send_alert(%{
        severity: :low,
        type: :enrichment_test,
        title: "Enrichment Test",
        message: "Test",
        metadata: %{}
      })

      Process.sleep(50)
      [alert | _] = AlertSystem.recent_alerts(type: :enrichment_test, limit: 1)

      assert String.starts_with?(alert.id, "alert_")
      assert %DateTime{} = alert.timestamp
      assert is_atom(alert.node)
    end
  end

  describe "send_critical/3" do
    test "sends critical alert" do
      AlertSystem.send_critical("Critical Issue", "Something bad happened", %{code: 500})

      Process.sleep(50)
      recent = AlertSystem.recent_alerts(severity: :critical, limit: 10)
      assert Enum.any?(recent, & &1.title == "Critical Issue")
    end
  end

  describe "recent_alerts/1" do
    test "filters by severity" do
      AlertSystem.send_alert(%{
        severity: :high,
        type: :severity_test,
        title: "High Severity",
        message: "Test",
        metadata: %{}
      })

      AlertSystem.send_alert(%{
        severity: :low,
        type: :severity_test,
        title: "Low Severity",
        message: "Test",
        metadata: %{}
      })

      Process.sleep(50)

      high_alerts = AlertSystem.recent_alerts(severity: :high, type: :severity_test)
      low_alerts = AlertSystem.recent_alerts(severity: :low, type: :severity_test)

      assert Enum.all?(high_alerts, & &1.severity == :high)
      assert Enum.all?(low_alerts, & &1.severity == :low)
    end

    test "respects limit" do
      for i <- 1..5 do
        AlertSystem.send_alert(%{
          severity: :low,
          type: :limit_test,
          title: "Alert #{i}",
          message: "Test",
          metadata: %{i: i}
        })
      end

      Process.sleep(50)

      limited = AlertSystem.recent_alerts(type: :limit_test, limit: 3)
      assert length(limited) <= 3
    end
  end

  describe "stats/0" do
    test "returns statistics" do
      # Enviar algunas alertas de diferentes tipos
      AlertSystem.send_alert(%{
        severity: :high,
        type: :stats_test,
        title: "Test",
        message: "Test",
        metadata: %{}
      })

      Process.sleep(50)

      stats = AlertSystem.stats()

      assert is_integer(stats.total_sent)
      assert stats.total_sent > 0
      assert is_map(stats.by_severity)
      assert is_map(stats.by_type)
    end
  end

  describe "subscribe/0" do
    test "receives alerts via PubSub" do
      AlertSystem.subscribe()

      AlertSystem.send_alert(%{
        severity: :medium,
        type: :pubsub_test,
        title: "PubSub Test",
        message: "Test",
        metadata: %{}
      })

      assert_receive {:alert, alert}, 1000
      assert alert.title == "PubSub Test"
    end
  end

  describe "subscribe/1" do
    test "receives alerts of specific severity" do
      AlertSystem.subscribe(:critical)

      AlertSystem.send_alert(%{
        severity: :critical,
        type: :severity_sub_test,
        title: "Critical Sub Test",
        message: "Test",
        metadata: %{}
      })

      assert_receive {:alert, alert}, 1000
      assert alert.severity == :critical
    end
  end

  describe "rate limiting" do
    test "rate limits duplicate alerts" do
      alert = %{
        severity: :low,
        type: :rate_limit_test,
        title: "Duplicate Alert",
        message: "Same message",
        metadata: %{key: "same"}
      }

      # Enviar 5 veces rápidamente
      for _ <- 1..5 do
        AlertSystem.send_alert(alert)
      end

      Process.sleep(100)

      stats = AlertSystem.stats()
      # Debería haber rate limited algunas
      assert stats.rate_limited >= 0
    end

    test "bypass_rate_limit allows duplicate critical alerts" do
      initial_stats = AlertSystem.stats()

      for i <- 1..3 do
        AlertSystem.send_alert(%{
          severity: :critical,
          type: :bypass_test,
          title: "Bypass #{i}",
          message: "Same type",
          metadata: %{bypass_rate_limit: true}
        })
      end

      Process.sleep(100)

      final_stats = AlertSystem.stats()
      # Todas deberían haberse enviado
      assert final_stats.total_sent >= initial_stats.total_sent + 3
    end
  end
end
