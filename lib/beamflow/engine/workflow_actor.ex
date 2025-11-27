defmodule Beamflow.Engine.WorkflowActor do
  @moduledoc """
  Actor GenServer que representa una instancia de workflow en ejecución.

  Cada workflow activo es un proceso aislado que mantiene su propio estado,
  implementando el patrón Actor de Erlang/OTP. Esto permite tolerancia a
  fallos granular: si un workflow falla, no afecta a los demás.

  ## Estado del Actor

  El estado interno contiene:

    * `:id` - Identificador único del workflow
    * `:definition` - Definición de pasos y configuración
    * `:status` - Estado actual (`:pending`, `:running`, `:completed`, `:failed`)
    * `:history` - Historial de ejecución para auditoría

  ## Supervisión

  Este actor está diseñado para ejecutarse bajo `Beamflow.Engine.WorkflowSupervisor`,
  que implementa la estrategia `:one_for_one` para reinicio automático.

  ## Ejemplo

      # El actor se inicia a través del supervisor
      {:ok, pid} = Beamflow.Engine.WorkflowSupervisor.start_workflow("wf-1", %{})

      # Consultar estado
      state = Beamflow.Engine.WorkflowActor.get_state("wf-1")
      # => %{id: "wf-1", status: :pending, ...}
  """

  use GenServer

  require Logger

  alias Beamflow.Engine.Registry, as: WorkflowRegistry

  @typedoc "Identificador único de workflow"
  @type workflow_id :: String.t()

  @typedoc "Definición/configuración del workflow"
  @type workflow_def :: map()

  @typedoc "Estados posibles del workflow"
  @type status :: :pending | :running | :completed | :failed

  @typedoc "Estado interno del actor"
  @type state :: %{
          id: workflow_id(),
          definition: workflow_def(),
          status: status(),
          history: list()
        }

  # ============================================================================
  # API Pública
  # ============================================================================

  @doc """
  Inicia un nuevo actor de workflow.

  Este función es llamada por el `DynamicSupervisor` y no debe invocarse
  directamente. Use `Beamflow.Engine.WorkflowSupervisor.start_workflow/2`.

  ## Parámetros

    * `{id, definition}` - Tupla con ID y definición del workflow
  """
  @spec start_link({workflow_id(), workflow_def()}) :: GenServer.on_start()
  def start_link({id, definition}) do
    GenServer.start_link(__MODULE__, {id, definition}, name: WorkflowRegistry.via_tuple(id))
  end

  @doc """
  Obtiene el estado actual del workflow.

  ## Parámetros

    * `workflow_id` - Identificador del workflow

  ## Retorno

  Mapa con el estado completo del workflow.

  ## Ejemplo

      iex> get_state("order-123")
      %{id: "order-123", status: :running, definition: %{}, history: []}
  """
  @spec get_state(workflow_id()) :: state()
  def get_state(workflow_id) do
    GenServer.call(WorkflowRegistry.via_tuple(workflow_id), :get_state)
  end

  # ============================================================================
  # Callbacks GenServer
  # ============================================================================

  @impl true
  def init({id, definition}) do
    Logger.info("Starting workflow actor for #{id}")

    state = %{
      id: id,
      definition: definition,
      status: :pending,
      history: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
end
