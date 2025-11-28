defmodule Beamflow.Engine.WorkflowActor do
  @moduledoc """
  Actor GenServer polimórfico para ejecutar workflows de cualquier dominio.

  Este actor es el corazón del motor de workflows de BEAMFlow. Es completamente
  **agnóstico del dominio**: no sabe nada sobre seguros, préstamos u otros casos
  de uso específicos. En su lugar, trabaja con módulos que implementan el
  behaviour `Beamflow.Workflows.Workflow`.

  ## Arquitectura Polimórfica

  El actor recibe un `workflow_module` que define:
  - Qué steps ejecutar (`steps/0`)
  - Cómo inicializar el estado (`initial_state/1`)
  - Qué hacer cuando un step tiene éxito (`handle_step_success/2`)
  - Qué hacer cuando un step falla (`handle_step_failure/3`)

  Esto permite que el mismo GenServer ejecute workflows de seguros, préstamos,
  procesamiento de órdenes, etc., sin cambiar una línea de código.

  ## Ciclo de Vida del Workflow

  1. **Inicio**: `init/1` recibe `{workflow_module, id, params}`
  2. **Inicialización**: Llama a `workflow_module.initial_state(params)`
  3. **Ejecución**: `handle_continue(:execute_next_step)` ejecuta steps secuencialmente
  4. **Por cada step**:
     - Valida con `step.validate(state)` (si está implementado)
     - Ejecuta con `step.execute(state)`
     - Si éxito: llama a `workflow_module.handle_step_success/2`
     - Si fallo: llama a `workflow_module.handle_step_failure/3`
  5. **Finalización**: Cuando `current_step >= total_steps`, marca como `:completed`

  ## Tolerancia a Fallos

  - Cada workflow es un proceso aislado
  - Supervisado por `Beamflow.Engine.WorkflowSupervisor`
  - Si crash, el supervisor reinicia el proceso
  - Estado persistido en Mnesia permite recuperación

  ## Ejemplo de Uso

      # Iniciar workflow de seguros
      {:ok, pid} = Beamflow.Engine.WorkflowSupervisor.start_workflow(
        Beamflow.Domains.Insurance.InsuranceWorkflow,
        "req-123",
        %{"applicant_name" => "Juan Pérez", "dni" => "12345678"}
      )

      # El actor ejecuta automáticamente los steps definidos
      # en InsuranceWorkflow.steps/0

  Ver ADR-003 para la justificación de esta arquitectura polimórfica.
  """

  use GenServer

  require Logger

  alias Beamflow.Engine.Idempotency
  alias Beamflow.Engine.Registry, as: WorkflowRegistry
  alias Beamflow.Storage.WorkflowStore

  @typedoc "Identificador único de workflow"
  @type workflow_id :: String.t()

  @typedoc "Módulo que implementa Beamflow.Workflows.Workflow"
  @type workflow_module :: module()

  @typedoc "Estados posibles del workflow"
  @type status :: :pending | :running | :completed | :failed

  @typedoc "Estado interno del actor"
  @type actor_state :: %{
          workflow_module: workflow_module(),
          workflow_id: workflow_id(),
          workflow_state: map(),
          steps: [module()],
          current_step_index: non_neg_integer(),
          total_steps: non_neg_integer(),
          status: status(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          error: term() | nil
        }

  # ============================================================================
  # API Pública
  # ============================================================================

  @doc """
  Inicia un nuevo actor de workflow polimórfico.

  Esta función es llamada por el `DynamicSupervisor` y no debe invocarse
  directamente. Use `Beamflow.Engine.WorkflowSupervisor.start_workflow/3`.

  ## Parámetros

    * `opts` - Keyword list con:
      * `:workflow_module` - Módulo que implementa `Beamflow.Workflows.Workflow`
      * `:workflow_id` - Identificador único del workflow
      * `:params` - Parámetros de entrada para `initial_state/1`

  ## Ejemplo

      start_link([
        workflow_module: InsuranceWorkflow,
        workflow_id: "req-123",
        params: %{"dni" => "12345678"}
      ])
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    workflow_id = Keyword.fetch!(opts, :workflow_id)

    GenServer.start_link(__MODULE__, opts, name: WorkflowRegistry.via_tuple(workflow_id))
  end

  @doc """
  Obtiene el estado actual del workflow.

  ## Parámetros

    * `workflow_id` - Identificador del workflow

  ## Retorno

  Mapa con el estado del workflow y metadatos del actor.

  ## Ejemplo

      iex> get_state("req-123")
      %{
        workflow_id: "req-123",
        status: :running,
        current_step_index: 2,
        total_steps: 4,
        workflow_state: %{dni: "12345678", credit_score: 750}
      }
  """
  @spec get_state(workflow_id()) :: {:ok, actor_state()} | {:error, :not_found}
  def get_state(workflow_id) do
    case WorkflowRegistry.lookup(workflow_id) do
      [{pid, _}] when is_pid(pid) ->
        {:ok, GenServer.call(WorkflowRegistry.via_tuple(workflow_id), :get_state)}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Ejecuta manualmente el siguiente step del workflow.

  Útil para workflows pausados o para testing.

  ## Parámetros

    * `workflow_id` - Identificador del workflow

  ## Retorno

    * `:ok` - Step ejecutado (o workflow ya completado)
    * `{:error, reason}` - Error al ejecutar
  """
  @spec execute_next_step(workflow_id()) :: :ok | {:error, term()}
  def execute_next_step(workflow_id) do
    GenServer.cast(WorkflowRegistry.via_tuple(workflow_id), :execute_next_step)
  end

  # ============================================================================
  # Callbacks GenServer
  # ============================================================================

  @impl true
  def init(opts) do
    workflow_module = Keyword.fetch!(opts, :workflow_module)
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    params = Keyword.get(opts, :params, %{})

    Logger.info("Starting workflow actor: #{workflow_id} (module: #{inspect(workflow_module)})")

    # Obtener steps del workflow
    steps = workflow_module.steps()
    total_steps = length(steps)

    # Inicializar estado del workflow usando el callback del módulo
    workflow_state = workflow_module.initial_state(params)

    actor_state = %{
      workflow_module: workflow_module,
      workflow_id: workflow_id,
      workflow_state: workflow_state,
      steps: steps,
      current_step_index: 0,
      total_steps: total_steps,
      status: :pending,
      started_at: DateTime.utc_now(),
      completed_at: nil,
      error: nil
    }

    # Persistir estado inicial y registrar evento
    persist_state(actor_state)
    record_event(workflow_id, :workflow_started, %{workflow_module: workflow_module, params: params})

    # Iniciar ejecución automática
    {:ok, actor_state, {:continue, :execute_next_step}}
  end

  @impl true
  def handle_continue(:execute_next_step, %{status: :completed} = state) do
    # Workflow ya completado, no hacer nada
    {:noreply, state}
  end

  @impl true
  def handle_continue(:execute_next_step, %{status: :failed} = state) do
    # Workflow falló, no continuar
    {:noreply, state}
  end

  @impl true
  def handle_continue(:execute_next_step, state) do
    %{
      current_step_index: index,
      total_steps: total,
      steps: steps,
      workflow_module: workflow_module,
      workflow_state: workflow_state,
      workflow_id: workflow_id
    } = state

    cond do
      # Todos los steps completados
      index >= total ->
        Logger.info("Workflow #{workflow_id} completed successfully")

        new_state = %{state |
          status: :completed,
          completed_at: DateTime.utc_now()
        }

        # Registrar evento de completado
        record_event(workflow_id, :workflow_completed, %{
          total_steps: total,
          duration_ms: DateTime.diff(new_state.completed_at, new_state.started_at, :millisecond)
        })

        broadcast_update(new_state)
        persist_state(new_state)

        {:noreply, new_state}

      # Ejecutar siguiente step
      true ->
        step_module = Enum.at(steps, index)

        Logger.info("Workflow #{workflow_id}: Executing step #{index + 1}/#{total} (#{inspect(step_module)})")

        new_state = %{state | status: :running}

        # Validar si el step implementa validate/1
        case validate_step(step_module, workflow_state) do
          :ok ->
            execute_step(step_module, workflow_module, new_state)

          {:error, validation_error} ->
            Logger.error("Workflow #{workflow_id}: Step validation failed - #{inspect(validation_error)}")

            handle_step_error(step_module, validation_error, workflow_module, new_state)
        end
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:execute_next_step, state) do
    {:noreply, state, {:continue, :execute_next_step}}
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  defp validate_step(step_module, workflow_state) do
    if function_exported?(step_module, :validate, 1) do
      step_module.validate(workflow_state)
    else
      :ok
    end
  end

  defp execute_step(step_module, workflow_module, state) do
    %{workflow_state: workflow_state, workflow_id: workflow_id, current_step_index: step_index} = state
    step_name = inspect(step_module)
    start_time = System.monotonic_time(:millisecond)

    # ══════════════════════════════════════════════════════════════════════════
    # IDEMPOTENCIA CENTRALIZADA - FASE 1: BEFORE EXECUTE
    # ══════════════════════════════════════════════════════════════════════════
    # Verificamos si el step ya se ejecutó (crash recovery) o está pendiente.
    # Esto garantiza exactly-once para side-effects externos.
    # ══════════════════════════════════════════════════════════════════════════
    case Idempotency.begin_step(workflow_id, step_module) do
      {:already_completed, cached_result} ->
        # Step ya completado anteriormente - usar resultado cacheado
        Logger.info("Workflow #{workflow_id}: Step #{step_name} already completed, using cached result")

        record_event(workflow_id, :step_skipped, %{
          step: step_name,
          step_index: step_index,
          reason: :idempotency_cache_hit
        })

        advance_to_next_step(step_module, workflow_module, state, cached_result)

      {:already_pending, idempotency_key} ->
        # Step pendiente (posible crash recovery) - reintentar con misma key
        Logger.warning("Workflow #{workflow_id}: Step #{step_name} was pending, retrying with same key")
        do_execute_step(step_module, workflow_module, state, idempotency_key, start_time)

      {:ok, idempotency_key} ->
        # Caso normal - nueva ejecución
        record_event(workflow_id, :step_started, %{step: step_name, step_index: step_index})
        do_execute_step(step_module, workflow_module, state, idempotency_key, start_time)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # IDEMPOTENCIA CENTRALIZADA - FASE 2: EXECUTE
  # ════════════════════════════════════════════════════════════════════════════
  # Ejecuta el step inyectando la idempotency_key en el estado.
  # Los steps con side-effects pueden usar esta key para llamadas externas.
  # ════════════════════════════════════════════════════════════════════════════
  defp do_execute_step(step_module, workflow_module, state, idempotency_key, start_time) do
    %{workflow_state: workflow_state, workflow_id: workflow_id, current_step_index: step_index} = state
    step_name = inspect(step_module)

    # Inyectar idempotency_key en el estado del workflow
    # Los steps pueden usarla para llamadas a servicios externos
    enriched_state = Map.put(workflow_state, :idempotency_key, idempotency_key)

    case step_module.execute(enriched_state) do
      {:ok, updated_workflow_state} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        Logger.debug("Workflow #{workflow_id}: Step #{step_name} succeeded in #{duration_ms}ms")

        # ════════════════════════════════════════════════════════════════════════
        # IDEMPOTENCIA CENTRALIZADA - FASE 3: AFTER EXECUTE (SUCCESS)
        # ════════════════════════════════════════════════════════════════════════
        # Marcar como completado DESPUÉS del side-effect pero ANTES de persistir.
        # Si crash aquí, el step se considera completado y no se re-ejecuta.
        # ════════════════════════════════════════════════════════════════════════
        Idempotency.complete_step(idempotency_key, updated_workflow_state)

        record_event(workflow_id, :step_completed, %{
          step: step_name,
          step_index: step_index,
          duration_ms: duration_ms,
          idempotency_key: idempotency_key
        })

        advance_to_next_step(step_module, workflow_module, state, updated_workflow_state)

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        Logger.error("Workflow #{workflow_id}: Step #{step_name} failed in #{duration_ms}ms - #{inspect(reason)}")

        # ════════════════════════════════════════════════════════════════════════
        # IDEMPOTENCIA CENTRALIZADA - FASE 3: AFTER EXECUTE (FAILURE)
        # ════════════════════════════════════════════════════════════════════════
        # Marcar como fallido permite retries con nueva key de intento.
        # ════════════════════════════════════════════════════════════════════════
        Idempotency.fail_step(idempotency_key, reason)

        record_event(workflow_id, :step_failed, %{
          step: step_name,
          step_index: step_index,
          duration_ms: duration_ms,
          error: inspect(reason),
          idempotency_key: idempotency_key
        })

        handle_step_error(step_module, reason, workflow_module, state)
    end
  end

  defp advance_to_next_step(step_module, workflow_module, state, updated_workflow_state) do
    # Llamar al callback de éxito del workflow
    new_workflow_state =
      workflow_module.handle_step_success(step_module, updated_workflow_state)

    new_state = %{state |
      workflow_state: new_workflow_state,
      current_step_index: state.current_step_index + 1
    }

    broadcast_update(new_state)
    persist_state(new_state)

    # Continuar con el siguiente step
    {:noreply, new_state, {:continue, :execute_next_step}}
  end

  defp handle_step_error(step_module, reason, workflow_module, state) do
    %{workflow_state: workflow_state, workflow_id: workflow_id} = state

    # Llamar al callback de fallo del workflow
    new_workflow_state =
      workflow_module.handle_step_failure(step_module, reason, workflow_state)

    new_state = %{state |
      workflow_state: new_workflow_state,
      status: :failed,
      error: reason,
      completed_at: DateTime.utc_now()
    }

    # Registrar fallo del workflow
    record_event(workflow_id, :workflow_failed, %{
      step: inspect(step_module),
      error: inspect(reason)
    })

    broadcast_update(new_state)
    persist_state(new_state)

    {:noreply, new_state}
  end

  defp broadcast_update(state) do
    %{workflow_id: workflow_id} = state

    # Broadcast general para dashboard
    Phoenix.PubSub.broadcast(
      Beamflow.PubSub,
      "workflows",
      {:workflow_updated, summarize_state(state)}
    )

    # Broadcast específico para detalle del workflow
    Phoenix.PubSub.broadcast(
      Beamflow.PubSub,
      "workflow:#{workflow_id}",
      {:workflow_updated, summarize_state(state)}
    )
  end

  defp persist_state(state) do
    case WorkflowStore.save_workflow(state) do
      {:ok, _record} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist workflow #{state.workflow_id}: #{inspect(reason)}")
        :ok  # No fallar el workflow por error de persistencia
    end
  end

  defp record_event(workflow_id, event_type, data) do
    case WorkflowStore.record_event(workflow_id, event_type, data) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("Failed to record event #{event_type} for #{workflow_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp summarize_state(state) do
    %{
      workflow_id: state.workflow_id,
      workflow_module: state.workflow_module,
      status: state.status,
      current_step_index: state.current_step_index,
      total_steps: state.total_steps,
      workflow_state: state.workflow_state,
      started_at: state.started_at,
      completed_at: state.completed_at,
      error: state.error
    }
  end
end
