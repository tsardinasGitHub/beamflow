defmodule Beamflow.Chaos.ChaosMonkeyTest do
  @moduledoc """
  Tests para ChaosMonkey - Sistema de inyección de fallos.
  """

  use ExUnit.Case, async: false

  alias Beamflow.Chaos.ChaosMonkey

  setup do
    # Asegurar que ChaosMonkey está detenido
    ChaosMonkey.stop()
    ChaosMonkey.reset_stats()
    :ok
  end

  describe "start/1" do
    test "starts with default gentle profile" do
      assert :ok = ChaosMonkey.start()
      assert ChaosMonkey.enabled?()

      {profile, config} = ChaosMonkey.current_profile()
      assert profile == :gentle
      assert config.crash_probability == 0.05
    end

    test "starts with specified profile" do
      assert :ok = ChaosMonkey.start(:aggressive)
      assert ChaosMonkey.enabled?()

      {profile, config} = ChaosMonkey.current_profile()
      assert profile == :aggressive
      assert config.crash_probability == 0.30
    end

    test "starts with moderate profile" do
      assert :ok = ChaosMonkey.start(:moderate)

      {profile, config} = ChaosMonkey.current_profile()
      assert profile == :moderate
      assert config.crash_probability == 0.15
    end
  end

  describe "stop/0" do
    test "stops chaos mode" do
      ChaosMonkey.start()
      assert ChaosMonkey.enabled?()

      assert :ok = ChaosMonkey.stop()
      refute ChaosMonkey.enabled?()
    end
  end

  describe "set_profile/1" do
    test "changes profile while running" do
      ChaosMonkey.start(:gentle)

      assert :ok = ChaosMonkey.set_profile(:aggressive)

      {profile, _} = ChaosMonkey.current_profile()
      assert profile == :aggressive
    end
  end

  describe "inject/2" do
    test "returns error when chaos not enabled" do
      refute ChaosMonkey.enabled?()

      assert {:error, :chaos_not_enabled} = ChaosMonkey.inject(:crash)
    end

    test "injects crash when enabled" do
      ChaosMonkey.start()

      # No hay workflows corriendo, pero no debería fallar
      assert :ok = ChaosMonkey.inject(:crash, target: :random_workflow)
    end

    test "injects timeout when enabled" do
      ChaosMonkey.start()

      assert :ok = ChaosMonkey.inject(:timeout, target: :random_workflow)
    end

    test "injects error when enabled" do
      ChaosMonkey.start()

      assert :ok = ChaosMonkey.inject(:error, target: :random_workflow)
    end

    test "injects latency when enabled" do
      ChaosMonkey.start()

      assert :ok = ChaosMonkey.inject(:latency, target: :random_workflow)
    end

    test "injects compensation failure when enabled" do
      ChaosMonkey.start()

      assert :ok = ChaosMonkey.inject(:compensation_fail, target: :random_workflow)

      # Verificar que el flag está seteado
      assert :persistent_term.get(:chaos_compensation_fail, false) == true

      # Limpiar
      :persistent_term.put(:chaos_compensation_fail, false)
    end
  end

  describe "stats/0" do
    test "returns initial stats" do
      stats = ChaosMonkey.stats()

      assert stats.total_injections == 0
      assert stats.crashes == 0
      assert stats.timeouts == 0
      assert stats.enabled == false
    end

    test "tracks injections" do
      ChaosMonkey.start()
      ChaosMonkey.inject(:error)
      ChaosMonkey.inject(:latency)

      stats = ChaosMonkey.stats()

      assert stats.total_injections == 2
      assert stats.errors == 1
      assert stats.latencies == 1
    end

    test "includes uptime when started" do
      ChaosMonkey.start()
      Process.sleep(100)

      stats = ChaosMonkey.stats()

      assert stats.enabled == true
      assert stats.uptime_seconds >= 0
      assert stats.started_at != nil
    end
  end

  describe "events/1" do
    test "returns recent events" do
      ChaosMonkey.start()
      ChaosMonkey.inject(:error)
      ChaosMonkey.inject(:crash)

      events = ChaosMonkey.events(limit: 10)

      assert is_list(events)
      # Los eventos son internos, pueden o no estar dependiendo de timing
    end
  end

  describe "reset_stats/0" do
    test "resets all statistics" do
      ChaosMonkey.start()
      ChaosMonkey.inject(:error)
      ChaosMonkey.inject(:crash)

      ChaosMonkey.reset_stats()

      stats = ChaosMonkey.stats()
      assert stats.total_injections == 0
      assert stats.errors == 0
      assert stats.crashes == 0
    end
  end

  describe "should_fail?/1" do
    test "returns false when disabled" do
      refute ChaosMonkey.enabled?()
      refute ChaosMonkey.should_fail?(:crash)
    end

    test "probabilistically returns true when enabled with aggressive profile" do
      ChaosMonkey.start(:aggressive)

      # Con 30% de probabilidad, en 100 intentos deberíamos tener algunos true
      results = for _ <- 1..100, do: ChaosMonkey.should_fail?(:crash)

      # Al menos uno debería ser true (probabilísticamente casi seguro)
      assert Enum.any?(results)
    end
  end

  describe "record_recovery/2" do
    test "records successful recovery" do
      ChaosMonkey.start()

      ChaosMonkey.record_recovery("wf-123", :retry)
      Process.sleep(50)

      stats = ChaosMonkey.stats()
      assert stats.successful_recoveries >= 1
    end
  end

  describe "profiles" do
    test "gentle has low probabilities" do
      ChaosMonkey.start(:gentle)
      {_, config} = ChaosMonkey.current_profile()

      assert config.crash_probability == 0.05
      assert config.timeout_probability == 0.03
      assert config.error_probability == 0.08
      assert config.interval_ms == 10_000
    end

    test "moderate has medium probabilities" do
      ChaosMonkey.start(:moderate)
      {_, config} = ChaosMonkey.current_profile()

      assert config.crash_probability == 0.15
      assert config.timeout_probability == 0.10
      assert config.error_probability == 0.20
      assert config.interval_ms == 5_000
    end

    test "aggressive has high probabilities" do
      ChaosMonkey.start(:aggressive)
      {_, config} = ChaosMonkey.current_profile()

      assert config.crash_probability == 0.30
      assert config.timeout_probability == 0.20
      assert config.error_probability == 0.35
      assert config.interval_ms == 2_000
    end
  end
end
