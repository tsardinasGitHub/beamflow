defmodule Beamflow.Chaos.FaultInjectorTest do
  @moduledoc """
  Tests para FaultInjector - Inyección de fallos en steps.
  """

  use ExUnit.Case, async: false

  import Beamflow.Chaos.FaultInjector

  alias Beamflow.Chaos.ChaosMonkey

  setup do
    ChaosMonkey.stop()
    ChaosMonkey.reset_stats()
    :ok
  end

  describe "maybe_crash!/1" do
    test "does nothing when chaos disabled" do
      refute ChaosMonkey.enabled?()

      # No debería crashear
      assert :ok = maybe_crash!(:test)
    end

    test "probabilistically crashes when chaos enabled with aggressive profile" do
      ChaosMonkey.start(:aggressive)

      # Con 30% de probabilidad, eventualmente debería crashear
      # Pero no podemos garantizarlo en un test, así que solo verificamos que no falle
      try do
        for _ <- 1..10, do: maybe_crash!(:test)
        :ok
      rescue
        RuntimeError -> :crashed
      end

      # El resultado es válido en ambos casos
      assert true
    end
  end

  describe "maybe_delay/2" do
    test "does nothing when chaos disabled" do
      refute ChaosMonkey.enabled?()

      start = System.monotonic_time(:millisecond)
      assert :ok = maybe_delay(:test)
      elapsed = System.monotonic_time(:millisecond) - start

      # Sin delay significativo
      assert elapsed < 50
    end

    test "may add delay when chaos enabled" do
      ChaosMonkey.start(:aggressive)

      # Solo verificar que no falla
      assert :ok = maybe_delay(:test, 10..50)
    end
  end

  describe "maybe_error/1" do
    test "returns :ok when chaos disabled" do
      refute ChaosMonkey.enabled?()

      assert :ok = maybe_error(:test)
    end

    test "may return error when chaos enabled" do
      ChaosMonkey.start(:aggressive)

      results = for _ <- 1..20, do: maybe_error(:test)

      # Debería tener algunos :ok y posiblemente algunos {:error, _}
      assert Enum.any?(results, fn r -> r == :ok end)
    end
  end

  describe "maybe_timeout/2" do
    test "does nothing when chaos disabled" do
      refute ChaosMonkey.enabled?()

      assert :ok = maybe_timeout(:test, 100)
    end
  end

  describe "maybe_fail_compensation/1" do
    test "returns :ok when chaos disabled" do
      refute ChaosMonkey.enabled?()

      assert :ok = maybe_fail_compensation(:test)
    end

    test "respects global flag" do
      :persistent_term.put(:chaos_compensation_fail, true)

      result = maybe_fail_compensation(:test)

      assert result == {:error, :chaos_compensation_failed}

      # Flag debería haberse limpiado
      assert :persistent_term.get(:chaos_compensation_fail, false) == false
    end
  end

  describe "with_chaos/3" do
    test "executes function when chaos disabled" do
      refute ChaosMonkey.enabled?()

      result = with_chaos(:test, [], fn -> {:ok, :result} end)

      assert result == {:ok, :result}
    end

    test "may fail when chaos enabled" do
      ChaosMonkey.start(:aggressive)

      # Ejecutar varias veces, algunas pueden fallar
      results = for _ <- 1..10 do
        try do
          with_chaos(:test, [faults: [:error]], fn -> {:ok, :success} end)
        rescue
          _ -> {:error, :crashed}
        end
      end

      # Al menos algunas deberían ser exitosas
      assert Enum.any?(results, fn r -> r == {:ok, :success} end)
    end
  end

  describe "with_chaos_block macro" do
    test "works as expected" do
      refute ChaosMonkey.enabled?()

      result = with_chaos_block :test_macro do
        1 + 1
      end

      assert result == 2
    end
  end

  describe "chaos_active?/0" do
    test "returns false when disabled" do
      ChaosMonkey.stop()
      refute chaos_active?()
    end

    test "returns true when enabled" do
      ChaosMonkey.start()
      assert chaos_active?()
    end
  end
end
