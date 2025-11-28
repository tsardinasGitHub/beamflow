defmodule Beamflow.Engine.RetryTest do
  @moduledoc """
  Tests para el sistema de retry con backoff exponencial
  """
  use ExUnit.Case, async: true

  alias Beamflow.Engine.Retry

  # ============================================================================
  # Tests para políticas predefinidas
  # ============================================================================

  describe "policy/1" do
    test "retorna política aggressive" do
      policy = Retry.policy(:aggressive)

      assert policy.max_attempts == 5
      assert policy.base_delay_ms == 1_000
      assert policy.max_delay_ms == 15_000
      assert policy.jitter == true
      assert policy.retryable_errors == :transient
    end

    test "retorna política conservative" do
      policy = Retry.policy(:conservative)

      assert policy.max_attempts == 3
      assert policy.base_delay_ms == 2_000
      assert policy.max_delay_ms == 30_000
    end

    test "retorna política patient" do
      policy = Retry.policy(:patient)

      assert policy.max_attempts == 10
      assert policy.base_delay_ms == 5_000
      assert policy.max_delay_ms == 300_000
    end

    test "retorna política email" do
      policy = Retry.policy(:email)

      assert policy.max_attempts == 5
      assert policy.base_delay_ms == 2_000
      assert :timeout in policy.retryable_errors
      assert :smtp_error in policy.retryable_errors
    end

    test "retorna política api" do
      policy = Retry.policy(:api)

      assert policy.max_attempts == 4
      assert policy.base_delay_ms == 500
      assert :bad_gateway in policy.retryable_errors
    end

    test "retorna política database" do
      policy = Retry.policy(:database)

      assert policy.max_attempts == 3
      assert policy.base_delay_ms == 100
      assert :deadlock in policy.retryable_errors
    end

    test "retorna política none (fail fast)" do
      policy = Retry.policy(:none)

      assert policy.max_attempts == 1
      assert policy.base_delay_ms == 0
      assert policy.retryable_errors == []
    end

    test "acepta map custom y hace merge con defaults" do
      policy = Retry.policy(%{max_attempts: 7})

      assert policy.max_attempts == 7
      # Hereda defaults de :conservative
      assert policy.jitter == true
    end
  end

  # ============================================================================
  # Tests para cálculo de delay
  # ============================================================================

  describe "calculate_delay/2" do
    test "delay base en primer intento" do
      policy = %{base_delay_ms: 1000, max_delay_ms: 30_000, jitter: false}

      assert Retry.calculate_delay(1, policy) == 1000
    end

    test "backoff exponencial en intentos sucesivos" do
      policy = %{base_delay_ms: 1000, max_delay_ms: 30_000, jitter: false}

      assert Retry.calculate_delay(1, policy) == 1000
      assert Retry.calculate_delay(2, policy) == 2000
      assert Retry.calculate_delay(3, policy) == 4000
      assert Retry.calculate_delay(4, policy) == 8000
      assert Retry.calculate_delay(5, policy) == 16000
    end

    test "delay no excede max_delay" do
      policy = %{base_delay_ms: 1000, max_delay_ms: 5000, jitter: false}

      # Intento 4 sería 8000, pero está capped a 5000
      assert Retry.calculate_delay(4, policy) == 5000
      assert Retry.calculate_delay(5, policy) == 5000
    end

    test "jitter agrega variación de ±10%" do
      policy = %{base_delay_ms: 10_000, max_delay_ms: 30_000, jitter: true}

      # Con jitter, el delay varía ±10% del valor base
      delays = for _ <- 1..100, do: Retry.calculate_delay(1, policy)

      min_delay = Enum.min(delays)
      max_delay = Enum.max(delays)

      # Debe variar (no todos iguales)
      assert min_delay != max_delay
      # Debe estar dentro del rango esperado (9000-11000 para base de 10000)
      assert min_delay >= 9000
      assert max_delay <= 11_000
    end
  end

  # ============================================================================
  # Tests para clasificación de errores
  # ============================================================================

  describe "retryable?/2" do
    test ":all considera todo retryable" do
      assert Retry.retryable?(:any_error, :all) == true
      assert Retry.retryable?(:validation_failed, :all) == true
    end

    test ":transient considera errores transitorios" do
      # Errores transitorios
      assert Retry.retryable?(:timeout, :transient) == true
      assert Retry.retryable?(:service_unavailable, :transient) == true
      assert Retry.retryable?(:connection_refused, :transient) == true
      assert Retry.retryable?(:rate_limited, :transient) == true

      # Errores no transitorios
      assert Retry.retryable?(:validation_failed, :transient) == false
      assert Retry.retryable?(:not_found, :transient) == false
    end

    test "lista específica de errores" do
      errors = [:timeout, :custom_error]

      assert Retry.retryable?(:timeout, errors) == true
      assert Retry.retryable?(:custom_error, errors) == true
      assert Retry.retryable?(:other_error, errors) == false
    end

    test "extrae átomo de tuplas de error" do
      assert Retry.retryable?({:timeout, "details"}, :transient) == true
      assert Retry.retryable?({:timeout, %{reason: "test"}}, :transient) == true
    end

    test "extrae átomo de mapas de error" do
      assert Retry.retryable?(%{type: :timeout}, :transient) == true
      assert Retry.retryable?(%{reason: :service_unavailable}, :transient) == true
    end

    test "errores desconocidos no son retryables por defecto" do
      assert Retry.retryable?("string error", :transient) == false
      assert Retry.retryable?(123, :transient) == false
    end
  end

  # ============================================================================
  # Tests para execute_with_retry/5
  # ============================================================================

  describe "execute_with_retry/5" do
    defmodule SuccessStep do
      def execute(state), do: {:ok, Map.put(state, :executed, true)}
    end

    defmodule AlwaysTimeoutStep do
      def execute(_state), do: {:error, :timeout}
    end

    defmodule AlwaysPermanentFailStep do
      def execute(_state), do: {:error, :permanent_failure}
    end

    test "éxito en primer intento" do
      policy = Retry.policy(:none)

      {:ok, result, retry_state} =
        Retry.execute_with_retry(SuccessStep, %{}, "wf-1", policy)

      assert result.executed == true
      assert retry_state.attempt == 1
    end

    test "no reintenta errores no-retryables" do
      policy = Retry.policy(%{
        max_attempts: 5,
        retryable_errors: [:timeout]  # permanent_failure no está
      })

      {:error, :permanent_failure, retry_state} =
        Retry.execute_with_retry(AlwaysPermanentFailStep, %{}, "wf-2", policy)

      # Solo 1 intento porque el error no es retryable
      assert retry_state.attempt == 1
    end

    test "reintenta errores transitorios hasta max_attempts" do
      policy = %{
        max_attempts: 3,
        base_delay_ms: 1,  # Delays mínimos para tests rápidos
        max_delay_ms: 10,
        jitter: false,
        retryable_errors: [:timeout]
      }

      {:error, :timeout, retry_state} =
        Retry.execute_with_retry(AlwaysTimeoutStep, %{}, "wf-3", policy)

      assert retry_state.attempt == 3
      assert length(retry_state.errors) == 3
    end

    test "llama callback on_retry en cada reintento" do
      test_pid = self()

      policy = %{
        max_attempts: 3,
        base_delay_ms: 1,
        max_delay_ms: 10,
        jitter: false,
        retryable_errors: [:timeout]
      }

      on_retry = fn attempt, delay, error ->
        send(test_pid, {:retry, attempt, delay, error})
      end

      {:error, _, _} =
        Retry.execute_with_retry(
          AlwaysTimeoutStep,
          %{},
          "wf-4",
          policy,
          on_retry: on_retry
        )

      # Debería recibir 2 callbacks (después de intento 1 y 2, antes de 2 y 3)
      assert_receive {:retry, 1, _, :timeout}
      assert_receive {:retry, 2, _, :timeout}
    end
  end

  # ============================================================================
  # Tests para macro __using__
  # ============================================================================

  describe "use Beamflow.Engine.Retry" do
    test "define __retry_policy__/0 con política nombrada" do
      defmodule TestStepWithPolicy do
        use Beamflow.Engine.Retry, policy: :email
      end

      policy = TestStepWithPolicy.__retry_policy__()
      assert policy.max_attempts == 5
      assert :smtp_error in policy.retryable_errors
    end

    test "define __retry_policy__/0 con opciones custom" do
      defmodule TestStepCustom do
        use Beamflow.Engine.Retry, max_attempts: 7, base_delay_ms: 500
      end

      policy = TestStepCustom.__retry_policy__()
      assert policy.max_attempts == 7
      assert policy.base_delay_ms == 500
    end
  end
end
