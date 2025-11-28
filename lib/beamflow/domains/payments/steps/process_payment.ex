defmodule Beamflow.Domains.Payments.Steps.ProcessPayment do
  @moduledoc """
  Step de ejemplo que demuestra la integración completa de:
  - **Circuit Breaker**: Protege el servicio de pagos de sobrecarga
  - **Saga Pattern**: Define compensación (refund) si steps posteriores fallan
  - **Retry con Backoff**: Reintenta automáticamente errores transitorios

  ## Flujo de Ejecución

  ```
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │                         ProcessPayment Flow                                  │
  │                                                                             │
  │  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐                │
  │  │   Circuit    │────►│    Retry     │────►│   Payment    │                │
  │  │   Breaker    │     │   (5 tries)  │     │   Gateway    │                │
  │  └──────────────┘     └──────────────┘     └──────────────┘                │
  │         │                    │                    │                         │
  │         ▼                    ▼                    ▼                         │
  │   :circuit_open        backoff exp.         {:ok, tx_id}                   │
  │   (fail fast)          + jitter             {:error, reason}               │
  │                                                                             │
  │  ═══════════════════════════════════════════════════════════════════════   │
  │                                                                             │
  │  Si step posterior falla → compensate/2 ejecuta REFUND                     │
  │                                                                             │
  └─────────────────────────────────────────────────────────────────────────────┘
  ```

  ## Uso

  Este step espera en el contexto:
  - `card_id` o `payment_method_id` - Identificador del método de pago
  - `amount` - Monto a cobrar (número)
  - `currency` - Moneda (default: "USD")
  - `description` - Descripción del cargo (opcional)

  ## Ejemplo

      context = %{
        card_id: "card_1234567890",
        amount: 99.99,
        currency: "USD",
        description: "Premium subscription"
      }

      ProcessPayment.execute(context)
      # => {:ok, %{...context, payment_tx: %{id: "tx_abc", status: "captured"}}}

  ## Compensación

  Si un step posterior al pago falla, `compensate/2` es llamado automáticamente:

      ProcessPayment.compensate(context, [])
      # Ejecuta refund del payment_tx.id
  """

  @behaviour Beamflow.Workflows.Step
  use Beamflow.Engine.Saga
  use Beamflow.Engine.Retry, policy: :payment

  require Logger

  alias Beamflow.Engine.CircuitBreaker

  @circuit_breaker_name :payment_gateway

  # ============================================================================
  # Step Implementation
  # ============================================================================

  @impl Beamflow.Workflows.Step
  def execute(state) do
    amount = state[:amount] || state["amount"]
    card_id = state[:card_id] || state[:payment_method_id] || state["card_id"]
    currency = state[:currency] || state["currency"] || "USD"
    description = state[:description] || state["description"] || "BEAMFlow charge"
    idempotency_key = state[:idempotency_key]

    Logger.info("ProcessPayment: Charging #{format_amount(amount, currency)} to #{mask_card(card_id)}")

    # Asegurar que el Circuit Breaker existe
    ensure_circuit_breaker()

    # Ejecutar a través del Circuit Breaker
    case CircuitBreaker.call(@circuit_breaker_name, fn ->
      process_payment(card_id, amount, currency, description, idempotency_key)
    end) do
      {:ok, transaction} ->
        Logger.info("ProcessPayment: Charge successful - TX: #{transaction.id}")

        updated_state =
          state
          |> Map.put(:payment_tx, transaction)
          |> Map.put(:payment_status, :captured)
          |> Map.put(:payment_amount, amount)
          |> Map.put(:payment_currency, currency)

        {:ok, updated_state}

      {:error, :circuit_open} ->
        Logger.error("ProcessPayment: Circuit breaker OPEN - payment gateway unavailable")
        {:error, :payment_gateway_unavailable}

      {:error, reason} ->
        Logger.error("ProcessPayment: Charge failed - #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Saga Compensation
  # ============================================================================

  @impl Beamflow.Engine.Saga
  def compensate(context, _opts) do
    payment_tx = context[:payment_tx]
    amount = context[:payment_amount]
    currency = context[:payment_currency]

    if payment_tx do
      Logger.warning(
        "ProcessPayment: COMPENSATING - Refunding #{format_amount(amount, currency)} for TX: #{payment_tx.id}"
      )

      # Asegurar que el Circuit Breaker existe
      ensure_circuit_breaker()

      case CircuitBreaker.call(@circuit_breaker_name, fn ->
        process_refund(payment_tx.id, amount, context[:idempotency_key])
      end) do
        {:ok, refund} ->
          Logger.info("ProcessPayment: Refund successful - Refund ID: #{refund.id}")
          {:ok, %{refund_id: refund.id, original_tx: payment_tx.id}}

        {:error, :circuit_open} ->
          Logger.error("ProcessPayment: CRITICAL - Cannot refund, circuit breaker OPEN")
          # Esto debería ir a DLQ para intervención manual
          {:error, {:compensation_blocked, :circuit_open, payment_tx.id}}

        {:error, reason} ->
          Logger.error("ProcessPayment: CRITICAL - Refund failed: #{inspect(reason)}")
          # Esto debería ir a DLQ para intervención manual
          {:error, {:refund_failed, reason, payment_tx.id}}
      end
    else
      Logger.debug("ProcessPayment: No transaction to compensate")
      {:ok, :no_compensation_needed}
    end
  end

  @impl Beamflow.Engine.Saga
  def compensation_metadata do
    %{
      compensation_module: __MODULE__,
      compensation_timeout: 60_000,  # Más tiempo para refunds
      retry_compensation: true,       # Reintentar compensación si falla
      critical: true                  # Alertar si la compensación falla
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp ensure_circuit_breaker do
    case CircuitBreaker.get_or_start(@circuit_breaker_name) do
      {:ok, _pid} -> :ok
      {:error, reason} ->
        Logger.warning("Could not start circuit breaker: #{inspect(reason)}")
        :ok
    end
  end

  defp process_payment(card_id, amount, currency, description, idempotency_key) do
    # Simulación de llamada a gateway de pagos (Stripe, etc.)
    # En producción, esto sería una llamada HTTP real

    # Simular latencia de red
    Process.sleep(Enum.random(50..200))

    # Simular diferentes escenarios
    case simulate_payment_result() do
      :success ->
        {:ok, %{
          id: "tx_#{generate_id()}",
          status: "captured",
          amount: amount,
          currency: currency,
          card_id: card_id,
          description: description,
          idempotency_key: idempotency_key,
          created_at: DateTime.utc_now(),
          metadata: %{
            processor: "simulated_gateway",
            response_code: "00"
          }
        }}

      :declined ->
        {:error, :card_declined}

      :insufficient_funds ->
        {:error, :insufficient_funds}

      :timeout ->
        {:error, :timeout}

      :service_unavailable ->
        {:error, :service_unavailable}
    end
  end

  defp process_refund(transaction_id, amount, idempotency_key) do
    # Simulación de refund
    Process.sleep(Enum.random(50..150))

    # 95% de éxito en refunds
    if :rand.uniform(100) <= 95 do
      {:ok, %{
        id: "ref_#{generate_id()}",
        original_transaction: transaction_id,
        amount: amount,
        status: "refunded",
        idempotency_key: "#{idempotency_key}_refund",
        created_at: DateTime.utc_now()
      }}
    else
      {:error, :refund_failed}
    end
  end

  defp simulate_payment_result do
    # Distribución realista de resultados
    case :rand.uniform(100) do
      n when n <= 85 -> :success           # 85% éxito
      n when n <= 90 -> :declined          # 5% tarjeta rechazada
      n when n <= 93 -> :insufficient_funds # 3% fondos insuficientes
      n when n <= 97 -> :timeout           # 4% timeout (retryable)
      _ -> :service_unavailable            # 3% servicio caído (retryable)
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp format_amount(amount, currency) do
    "#{currency} #{:erlang.float_to_binary(amount * 1.0, decimals: 2)}"
  end

  defp mask_card(nil), do: "****"
  defp mask_card(card_id) when is_binary(card_id) do
    if String.length(card_id) > 8 do
      String.slice(card_id, 0, 4) <> "****" <> String.slice(card_id, -4, 4)
    else
      "****"
    end
  end
  defp mask_card(_), do: "****"
end
