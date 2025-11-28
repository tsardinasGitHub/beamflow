defmodule Beamflow.Chaos.Demo.ChaosAwareStep do
  @moduledoc """
  Step de demostración que integra chaos testing.

  Este step muestra cómo crear un step "chaos-aware" que:
  1. Puede experimentar fallos aleatorios durante chaos mode
  2. Implementa compensación idempotente
  3. Se recupera automáticamente de crashes
  4. Registra métricas de recovery

  ## Uso en Workflows

      defmodule MyWorkflow do
        use Beamflow.Workflows.Definition

        workflow do
          step :risky_operation, ChaosAwareStep
          step :next_step, AnotherStep
        end
      end
  """

  @behaviour Beamflow.Workflows.Step
  use Beamflow.Engine.Saga
  use Beamflow.Engine.Retry, policy: :conservative

  require Logger
  import Beamflow.Chaos.FaultInjector

  @impl Beamflow.Workflows.Step
  def execute(state) do
    Logger.info("🎲 ChaosAwareStep executing...")

    # Obtener o generar idempotency key
    idempotency_key = state[:idempotency_key] || generate_idempotency_key(state)

    # Verificar si ya se ejecutó (idempotencia)
    case check_already_executed(idempotency_key) do
      {:ok, cached_result} ->
        Logger.info("♻️  Returning cached result (idempotent)")
        {:ok, cached_result}

      :not_found ->
        execute_with_chaos(state, idempotency_key)
    end
  end

  defp execute_with_chaos(state, idempotency_key) do
    # Punto de inyección de chaos #1: Crash aleatorio
    maybe_crash!(:chaos_aware_step)

    # Punto de inyección de chaos #2: Latencia
    maybe_delay(:processing, 50..500)

    # Simular trabajo real
    result = process_data(state)

    # Punto de inyección de chaos #3: Error aleatorio
    case maybe_error(:result_processing) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        # Guardar resultado para idempotencia
        cache_result(idempotency_key, result)

        # Actualizar estado
        updated_state = Map.merge(state, %{
          chaos_step_completed: true,
          chaos_step_result: result,
          idempotency_key: idempotency_key,
          executed_at: DateTime.utc_now()
        })

        Logger.info("✅ ChaosAwareStep completed successfully")
        {:ok, updated_state}
    end
  end

  @impl Beamflow.Engine.Saga
  def compensate(context, _opts) do
    Logger.warning("🔄 ChaosAwareStep compensating...")

    idempotency_key = context[:idempotency_key]

    # Verificar si la compensación ya se ejecutó (idempotencia)
    compensation_key = "#{idempotency_key}_compensated"

    case check_already_compensated(compensation_key) do
      true ->
        Logger.info("♻️  Already compensated (idempotent)")
        {:ok, :already_compensated}

      false ->
        # Punto de inyección de chaos para compensación
        case maybe_fail_compensation(:chaos_aware_step) do
          {:error, reason} ->
            {:error, reason}

          :ok ->
            # Realizar compensación real
            undo_changes(context)

            # Marcar como compensado
            mark_compensated(compensation_key)

            # Registrar recovery si chaos mode está activo
            if chaos_active?() do
              Beamflow.Chaos.ChaosMonkey.record_recovery(
                context[:workflow_id] || "unknown",
                :saga_compensation
              )
            end

            Logger.info("✅ ChaosAwareStep compensation complete")
            {:ok, :compensated}
        end
    end
  end

  @impl Beamflow.Engine.Saga
  def compensation_metadata do
    %{
      compensation_timeout: 30_000,
      retry_compensation: true,
      critical: false
    }
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp generate_idempotency_key(state) do
    # Generar key basado en el contenido del estado
    data = :erlang.term_to_binary(state)
    hash = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    "chaos_step_#{String.slice(hash, 0, 16)}"
  end

  defp check_already_executed(key) do
    case :persistent_term.get({:chaos_step_cache, key}, :not_found) do
      :not_found -> :not_found
      result -> {:ok, result}
    end
  rescue
    _ -> :not_found
  end

  defp cache_result(key, result) do
    :persistent_term.put({:chaos_step_cache, key}, result)
  rescue
    _ -> :ok
  end

  defp check_already_compensated(key) do
    :persistent_term.get({:chaos_compensation, key}, false)
  rescue
    _ -> false
  end

  defp mark_compensated(key) do
    :persistent_term.put({:chaos_compensation, key}, true)
  rescue
    _ -> :ok
  end

  defp process_data(state) do
    # Simular procesamiento
    Process.sleep(Enum.random(10..50))

    %{
      processed: true,
      input_keys: Map.keys(state),
      processing_time_ms: System.monotonic_time(:millisecond),
      random_value: :rand.uniform(1000)
    }
  end

  defp undo_changes(context) do
    # Simular rollback
    Process.sleep(Enum.random(5..20))

    # Limpiar cache si existe
    if key = context[:idempotency_key] do
      try do
        :persistent_term.erase({:chaos_step_cache, key})
      rescue
        _ -> :ok
      end
    end

    :ok
  end
end
