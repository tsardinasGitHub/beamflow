defmodule Beamflow.Workflows.Workflow do
  @moduledoc """
  Behaviour para definir workflows ejecutables en BEAMFlow.

  Un workflow define una secuencia de steps que se ejecutan en orden,
  con manejo de estado y políticas de error personalizadas por dominio.

  ## Responsabilidades

  Un módulo que implementa este behaviour debe:

  1. **Definir los steps**: Lista ordenada de módulos Step a ejecutar
  2. **Estado inicial**: Transformar parámetros de entrada en estado interno
  3. **Manejo de éxito**: Actualizar estado tras completar un step
  4. **Manejo de fallos**: Decidir qué hacer cuando un step falla

  ## Ejemplo

      defmodule MyApp.Workflows.OrderFulfillment do
        @behaviour Beamflow.Workflows.Workflow

        alias MyApp.Steps.{ValidateInventory, ProcessPayment, ShipOrder}

        @impl true
        def steps do
          [ValidateInventory, ProcessPayment, ShipOrder]
        end

        @impl true
        def initial_state(params) do
          %{
            order_id: params["order_id"],
            items: params["items"],
            status: :pending,
            current_step: 0
          }
        end

        @impl true
        def handle_step_success(_step_module, state) do
          %{state | current_step: state.current_step + 1}
        end

        @impl true
        def handle_step_failure(_step_module, reason, state) do
          %{state | status: :failed, failure_reason: reason}
        end
      end

  ## Integración con WorkflowActor

  El `Beamflow.Engine.WorkflowActor` ejecutará automáticamente los steps
  definidos, llamando a los callbacks para gestionar el estado.

  Ver ADR-003 para la justificación arquitectónica de este diseño.
  """

  @type workflow_state :: map()
  @type step_module :: module()
  @type params :: map()

  @doc """
  Retorna la lista ordenada de steps a ejecutar.

  Los steps se ejecutan secuencialmente en el orden especificado.
  Cada step debe implementar el behaviour `Beamflow.Workflows.Step`.

  ## Retorno

  Lista de módulos que implementan `Beamflow.Workflows.Step`.

  ## Ejemplo

      @impl true
      def steps do
        [Step1, Step2, Step3]
      end

  """
  @callback steps() :: [step_module()]

  @doc """
  Transforma los parámetros de entrada en el estado inicial del workflow.

  Este callback se invoca una única vez al iniciar el workflow, antes
  de ejecutar cualquier step.

  ## Parámetros

  - `params` - Mapa con los datos de entrada (típicamente desde un formulario)

  ## Retorno

  Mapa que representa el estado inicial del workflow. Debe incluir
  al menos `current_step: 0`.

  ## Ejemplo

      @impl true
      def initial_state(params) do
        %{
          user_id: params["user_id"],
          amount: params["amount"],
          current_step: 0,
          status: :pending,
          started_at: DateTime.utc_now()
        }
      end

  """
  @callback initial_state(params()) :: workflow_state()

  @doc """
  Maneja el éxito de un step, actualizando el estado del workflow.

  Invocado después de que un step retorna `{:ok, updated_state}`.
  Típicamente incrementa `current_step` para avanzar al siguiente paso.

  ## Parámetros

  - `step_module` - El módulo del step que se completó exitosamente
  - `state` - El estado actualizado retornado por el step

  ## Retorno

  Nuevo estado del workflow, usualmente con `current_step` incrementado.

  ## Ejemplo

      @impl true
      def handle_step_success(step_module, state) do
        state
        |> Map.put(:current_step, state.current_step + 1)
        |> Map.put(:last_successful_step, step_module)
        |> Map.update(:history, [], &[{step_module, :success} | &1])
      end

  """
  @callback handle_step_success(step_module(), workflow_state()) :: workflow_state()

  @doc """
  Maneja el fallo de un step, decidiendo la política de error.

  Invocado cuando un step retorna `{:error, reason}`.

  ## Parámetros

  - `step_module` - El módulo del step que falló
  - `reason` - El término de error retornado por el step
  - `state` - El estado actual del workflow

  ## Retorno

  Estado actualizado del workflow. Comúnmente:
  - Marca `status: :failed`
  - Guarda `failure_reason`
  - Registra en history

  ## Políticas de Error Comunes

  - **Fail Fast**: Marcar como failed y detener
  - **Retry**: Mantener current_step y programar retry (futuro)
  - **Skip**: Avanzar al siguiente step con advertencia
  - **Compensate**: Ejecutar rollback de steps previos (avanzado)

  ## Ejemplo

      @impl true
      def handle_step_failure(step_module, reason, state) do
        %{state |
          status: :failed,
          failed_at_step: step_module,
          failure_reason: inspect(reason),
          retries: state[:retries] || 0
        }
      end

  """
  @callback handle_step_failure(step_module(), reason :: term(), workflow_state()) ::
              workflow_state()
end
