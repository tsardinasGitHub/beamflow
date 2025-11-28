defmodule Beamflow.Engine.Idempotency do
  @moduledoc """
  Sistema de idempotencia para garantizar ejecución exactamente-una-vez de steps.

  ## El Problema

  Cuando un nodo crashea a mitad de un step que tiene efectos secundarios
  (enviar email, llamar API externa, procesar pago), pueden ocurrir:

  1. **El step se ejecutó pero no se registró** → Al reiniciar, se ejecuta de nuevo
  2. **Duplicación de side-effects** → Emails duplicados, pagos dobles

  ## La Solución: Outbox Pattern + Idempotency Keys

  Este módulo implementa un patrón de tres fases:

  ```
  Fase 1: BEFORE_EXECUTE
  ─────────────────────────
  1. Generar idempotency_key único: "{workflow_id}:{step_index}:{attempt}"
  2. Registrar en Mnesia: {:pending, key, timestamp}
  3. Pasar key al step para side-effects

  Fase 2: EXECUTE
  ─────────────────────────
  4. Step usa key para llamadas externas (email, API, etc.)
  5. Servicios externos deben ser idempotentes con esta key

  Fase 3: AFTER_EXECUTE
  ─────────────────────────
  6. Registrar en Mnesia: {:completed, key, result}
  ```

  ## Recuperación ante Crash

  Al reiniciar el workflow:

  ```elixir
  case Idempotency.check_step_status(workflow_id, step_index) do
    :not_started ->
      # Ejecutar normalmente
      execute_step(...)

    {:pending, key, started_at} ->
      # Crash durante ejecución - verificar con servicio externo
      case verify_external_execution(key) do
        :executed -> skip_step_and_use_cached_result(...)
        :not_executed -> retry_with_same_key(key, ...)
      end

    {:completed, result} ->
      # Ya ejecutado - saltar
      skip_step_and_use_cached_result(result)
  end
  ```

  ## Ejemplo de Uso en Steps

  ```elixir
  defmodule MyApp.Steps.SendEmail do
    @behaviour Beamflow.Workflows.Step

    def execute(%{idempotency_key: key} = state) do
      # El servicio de email usa la key para deduplicar
      case EmailService.send(
        to: state.email,
        subject: "Confirmación",
        idempotency_key: key  # ← Clave para deduplicación
      ) do
        {:ok, _} -> {:ok, Map.put(state, :email_sent, true)}
        {:error, reason} -> {:error, reason}
      end
    end
  end
  ```

  ## Tabla Mnesia

  La tabla `:beamflow_idempotency` almacena:

  - `key`: "{workflow_id}:{step_module}:{attempt}"
  - `status`: `:pending` | `:completed` | `:failed`
  - `started_at`: Timestamp de inicio
  - `completed_at`: Timestamp de fin (si aplica)
  - `result`: Resultado del step (si completado)
  - `error`: Error (si falló)

  Ver ADR-004 para justificación detallada de esta decisión.
  """

  require Logger

  alias Beamflow.Storage.IdempotencyStore

  @type idempotency_key :: String.t()
  @type step_status ::
          :not_started
          | {:pending, idempotency_key(), DateTime.t()}
          | {:completed, map()}
          | {:failed, term()}

  @doc """
  Genera una clave de idempotencia única para un step.

  La clave incluye:
  - workflow_id: Identificador del workflow
  - step_module: Módulo del step (para debugging)
  - attempt: Número de intento (para retries controlados)

  ## Ejemplo

      iex> generate_key("req-123", ValidateIdentity, 1)
      "req-123:ValidateIdentity:1"
  """
  @spec generate_key(String.t(), module(), non_neg_integer()) :: idempotency_key()
  def generate_key(workflow_id, step_module, attempt \\ 1) do
    step_name = step_module |> Module.split() |> List.last()
    "#{workflow_id}:#{step_name}:#{attempt}"
  end

  @doc """
  Registra que un step está por comenzar (fase BEFORE_EXECUTE).

  Esto crea un registro "pending" en Mnesia ANTES de ejecutar el step.
  Si el nodo crashea, sabremos que el step estaba en progreso.

  ## Parámetros

  - `workflow_id` - ID del workflow
  - `step_module` - Módulo del step
  - `attempt` - Número de intento

  ## Retorno

  - `{:ok, idempotency_key}` - Key generada y registrada
  - `{:already_pending, key}` - Ya hay una ejecución pendiente
  - `{:already_completed, result}` - Step ya ejecutado exitosamente
  """
  @spec begin_step(String.t(), module(), non_neg_integer()) ::
          {:ok, idempotency_key()}
          | {:already_pending, idempotency_key()}
          | {:already_completed, map()}
  def begin_step(workflow_id, step_module, attempt \\ 1) do
    key = generate_key(workflow_id, step_module, attempt)

    case IdempotencyStore.get_status(key) do
      :not_found ->
        :ok = IdempotencyStore.mark_pending(key)
        Logger.debug("Idempotency: Step #{key} marked as pending")
        {:ok, key}

      {:pending, _started_at} ->
        Logger.warning("Idempotency: Step #{key} already pending (possible crash recovery)")
        {:already_pending, key}

      {:completed, result} ->
        Logger.info("Idempotency: Step #{key} already completed, skipping")
        {:already_completed, result}

      {:failed, _error} ->
        # Falló antes, permitir retry con nuevo intento
        new_key = generate_key(workflow_id, step_module, attempt + 1)
        :ok = IdempotencyStore.mark_pending(new_key)
        {:ok, new_key}
    end
  end

  @doc """
  Registra que un step completó exitosamente (fase AFTER_EXECUTE).

  ## Parámetros

  - `key` - Clave de idempotencia generada por `begin_step/3`
  - `result` - Resultado del step (nuevo workflow_state)
  """
  @spec complete_step(idempotency_key(), map()) :: :ok
  def complete_step(key, result) do
    :ok = IdempotencyStore.mark_completed(key, result)
    Logger.debug("Idempotency: Step #{key} marked as completed")
    :ok
  end

  @doc """
  Registra que un step falló.

  ## Parámetros

  - `key` - Clave de idempotencia
  - `error` - Razón del fallo
  """
  @spec fail_step(idempotency_key(), term()) :: :ok
  def fail_step(key, error) do
    :ok = IdempotencyStore.mark_failed(key, error)
    Logger.debug("Idempotency: Step #{key} marked as failed")
    :ok
  end

  @doc """
  Verifica el estado de un step para recuperación.

  Usado al reiniciar un workflow para determinar si un step
  necesita re-ejecutarse.

  ## Retorno

  - `:not_started` - Nunca se intentó
  - `{:pending, key, started_at}` - En progreso (posible crash)
  - `{:completed, result}` - Ejecutado exitosamente
  - `{:failed, error}` - Falló
  """
  @spec check_step_status(String.t(), module()) :: step_status()
  def check_step_status(workflow_id, step_module) do
    # Buscar el último intento
    key = generate_key(workflow_id, step_module, 1)
    IdempotencyStore.get_status(key)
  end

  @doc """
  Limpia registros de idempotencia antiguos.

  Útil para mantenimiento. Los registros completados pueden
  eliminarse después de un período de retención.

  ## Parámetros

  - `older_than` - Eliminar registros más antiguos que esta fecha
  """
  @spec cleanup(DateTime.t()) :: {:ok, non_neg_integer()}
  def cleanup(older_than) do
    IdempotencyStore.cleanup_older_than(older_than)
  end
end
