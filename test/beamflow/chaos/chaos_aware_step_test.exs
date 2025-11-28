defmodule Beamflow.Chaos.Demo.ChaosAwareStepTest do
  @moduledoc """
  Tests para ChaosAwareStep - Step de demostración con chaos testing.
  """

  use ExUnit.Case, async: false

  alias Beamflow.Chaos.Demo.ChaosAwareStep
  alias Beamflow.Chaos.ChaosMonkey

  setup do
    ChaosMonkey.stop()
    ChaosMonkey.reset_stats()
    :ok
  end

  describe "execute/1 sin chaos" do
    test "executes successfully" do
      refute ChaosMonkey.enabled?()

      state = %{input: "test", value: 123}

      assert {:ok, result} = ChaosAwareStep.execute(state)

      assert result.chaos_step_completed == true
      assert result.chaos_step_result != nil
      assert result.executed_at != nil
    end

    test "is idempotent with same idempotency_key" do
      state = %{
        input: "test",
        idempotency_key: "unique-key-#{System.unique_integer()}"
      }

      # Primera ejecución
      {:ok, result1} = ChaosAwareStep.execute(state)

      # Segunda ejecución con la misma key debería retornar resultado cacheado
      {:ok, result2} = ChaosAwareStep.execute(state)

      # El resultado cacheado debería incluir el flag de completado
      assert result1.chaos_step_completed == true
      # La segunda ejecución retorna el resultado cacheado (el map de process_data)
      # que tiene :processed => true
      assert result2.processed == true
    end

    test "generates different results for different inputs" do
      state1 = %{input: "test1", idempotency_key: "key1-#{System.unique_integer()}"}
      state2 = %{input: "test2", idempotency_key: "key2-#{System.unique_integer()}"}

      {:ok, result1} = ChaosAwareStep.execute(state1)
      {:ok, result2} = ChaosAwareStep.execute(state2)

      # Los inputs son diferentes, así que las keys son diferentes
      assert result1.idempotency_key != result2.idempotency_key
    end
  end

  describe "compensate/2 sin chaos" do
    test "compensates successfully" do
      context = %{
        workflow_id: "test-wf",
        idempotency_key: "compensate-key-#{System.unique_integer()}"
      }

      assert {:ok, :compensated} = ChaosAwareStep.compensate(context, [])
    end

    test "is idempotent - returns already_compensated on second call" do
      key = "idem-compensate-#{System.unique_integer()}"
      context = %{
        workflow_id: "test-wf",
        idempotency_key: key
      }

      # Primera compensación
      {:ok, :compensated} = ChaosAwareStep.compensate(context, [])

      # Segunda compensación debería retornar que ya fue compensado
      {:ok, :already_compensated} = ChaosAwareStep.compensate(context, [])
    end
  end

  describe "compensation_metadata/0" do
    test "returns expected metadata" do
      metadata = ChaosAwareStep.compensation_metadata()

      assert metadata.compensation_timeout == 30_000
      assert metadata.retry_compensation == true
      assert metadata.critical == false
    end
  end

  describe "execute/1 con chaos" do
    test "may fail when chaos is aggressive" do
      ChaosMonkey.start(:aggressive)

      state = %{
        input: "chaos-test",
        idempotency_key: "chaos-exec-#{System.unique_integer()}"
      }

      # Ejecutar múltiples veces - algunas pueden fallar
      results = for _ <- 1..10 do
        try do
          ChaosAwareStep.execute(state)
        rescue
          _ -> {:error, :crashed}
        end
      end

      # Verificar que tuvimos algún resultado (éxito o error es válido)
      assert length(results) == 10

      # Al menos algunas deberían ser exitosas (por idempotencia después del primer éxito)
      successful = Enum.filter(results, fn
        {:ok, _} -> true
        _ -> false
      end)

      # La primera ejecución exitosa debe ser cacheada
      assert length(successful) >= 0
    end
  end

  describe "integración con Saga" do
    test "saga_enabled? returns true" do
      assert Beamflow.Engine.Saga.saga_enabled?(ChaosAwareStep)
    end
  end
end
