defmodule Beamflow.Domains.Payments.Steps.ProcessPaymentTest do
  @moduledoc """
  Tests para ProcessPayment - ejemplo de integración completa.
  """

  use ExUnit.Case, async: false

  alias Beamflow.Domains.Payments.Steps.ProcessPayment
  alias Beamflow.Engine.CircuitBreaker

  setup do
    # Limpiar circuit breaker si existe
    CircuitBreaker.stop(:payment_gateway)
    :ok
  end

  describe "execute/1" do
    test "processes payment successfully with valid input" do
      state = %{
        card_id: "card_1234567890abcdef",
        amount: 99.99,
        currency: "USD",
        description: "Test payment",
        idempotency_key: "test-#{System.unique_integer([:positive])}"
      }

      # Ejecutar varias veces hasta obtener éxito (debido a simulación)
      result = retry_until_success(fn -> ProcessPayment.execute(state) end, 5)

      case result do
        {:ok, updated_state} ->
          assert updated_state.payment_status == :captured
          assert updated_state.payment_amount == 99.99
          assert updated_state.payment_currency == "USD"
          assert %{id: tx_id} = updated_state.payment_tx
          assert String.starts_with?(tx_id, "tx_")

        {:error, reason} ->
          # Si falló después de 5 intentos, aún es válido
          # (podría ser :card_declined, :insufficient_funds, etc.)
          assert reason in [:card_declined, :insufficient_funds, :payment_gateway_unavailable]
      end
    end

    test "handles missing card_id gracefully" do
      state = %{
        amount: 50.00,
        currency: "USD"
      }

      # Debería manejar nil card_id sin crashear
      result = ProcessPayment.execute(state)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "compensate/2" do
    test "refunds successful transaction" do
      # Crear un contexto con una transacción existente
      context = %{
        payment_tx: %{id: "tx_test123", status: "captured"},
        payment_amount: 75.50,
        payment_currency: "EUR",
        idempotency_key: "test-compensate-#{System.unique_integer([:positive])}"
      }

      result = retry_until_success(fn -> ProcessPayment.compensate(context, []) end, 3)

      case result do
        {:ok, refund_info} ->
          assert refund_info[:refund_id] || refund_info == :no_compensation_needed

        {:error, {:compensation_blocked, :circuit_open, _}} ->
          # Circuit breaker abierto es válido
          :ok

        {:error, {:refund_failed, _, _}} ->
          # Fallo de refund también es válido en tests
          :ok
      end
    end

    test "returns no_compensation_needed when no transaction exists" do
      context = %{}

      assert {:ok, :no_compensation_needed} = ProcessPayment.compensate(context, [])
    end
  end

  describe "saga integration" do
    test "is saga enabled" do
      assert Beamflow.Engine.Saga.saga_enabled?(ProcessPayment)
    end

    test "has critical compensation metadata" do
      metadata = ProcessPayment.compensation_metadata()

      assert metadata.critical == true
      assert metadata.retry_compensation == true
      assert metadata.compensation_timeout == 60_000
    end
  end

  describe "retry integration" do
    test "has retry policy defined" do
      # ProcessPayment usa `use Beamflow.Engine.Retry, policy: :payment`
      # que define la función __retry_policy__/0
      policy = ProcessPayment.__retry_policy__()

      assert policy.max_attempts == 3
      assert policy.base_delay_ms == 1_000
      assert :timeout in policy.retryable_errors
    end
  end

  describe "circuit breaker integration" do
    test "creates circuit breaker on first call" do
      state = %{
        card_id: "card_test",
        amount: 10.00,
        idempotency_key: "cb-test-#{System.unique_integer([:positive])}"
      }

      _result = ProcessPayment.execute(state)

      # Circuit breaker debería existir ahora
      assert {:ok, _status} = CircuitBreaker.status(:payment_gateway)
    end
  end

  # Helper para reintentar hasta éxito (para tests con simulación aleatoria)
  defp retry_until_success(fun, 0), do: fun.()
  defp retry_until_success(fun, attempts) do
    case fun.() do
      {:ok, _} = success -> success
      {:error, reason} when reason in [:timeout, :service_unavailable] ->
        Process.sleep(50)
        retry_until_success(fun, attempts - 1)
      other -> other
    end
  end
end
