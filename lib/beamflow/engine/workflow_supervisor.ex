defmodule Beamflow.Engine.WorkflowSupervisor do
  @moduledoc """
  Supervisor dinámico para procesos de workflow.

  Gestiona el ciclo de vida de `Beamflow.Engine.WorkflowActor`, permitiendo
  iniciar y detener workflows de forma dinámica bajo supervisión OTP.

  ## Arquitectura

  Este supervisor implementa el patrón "let it crash" de OTP: cada workflow
  se ejecuta en su propio proceso aislado. Si un workflow falla, solo ese
  proceso se ve afectado y puede ser reiniciado automáticamente.

  ## Ejemplo

      # Iniciar un nuevo workflow
      iex> Beamflow.Engine.WorkflowSupervisor.start_workflow("wf-123", %{steps: []})
      {:ok, #PID<0.123.0>}

      # Detener un workflow
      iex> Beamflow.Engine.WorkflowSupervisor.stop_workflow("wf-123")
      :ok
  """

  use DynamicSupervisor

  alias Beamflow.Engine.WorkflowActor

  @doc """
  Inicia el supervisor dinámico.

  Se invoca automáticamente por el árbol de supervisión de la aplicación.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Inicia un nuevo workflow bajo supervisión.

  ## Parámetros

    * `workflow_module` - Módulo que implementa `Beamflow.Workflows.Workflow`
    * `workflow_id` - Identificador único del workflow (String)
    * `params` - Parámetros de entrada para `workflow_module.initial_state/1`

  ## Retorno

    * `{:ok, pid}` - Workflow iniciado exitosamente
    * `{:error, {:already_started, pid}}` - Ya existe un workflow con ese ID
    * `{:error, reason}` - Error al iniciar

  ## Ejemplo

      iex> start_workflow(
      ...>   Beamflow.Domains.Insurance.InsuranceWorkflow,
      ...>   "req-123",
      ...>   %{"dni" => "12345678", "applicant_name" => "Juan"}
      ...> )
      {:ok, #PID<0.456.0>}
  """
  @spec start_workflow(module(), String.t(), map()) :: DynamicSupervisor.on_start_child()
  def start_workflow(workflow_module, workflow_id, params \\ %{}) do
    child_spec = %{
      id: WorkflowActor,
      start: {
        WorkflowActor,
        :start_link,
        [
          [
            workflow_module: workflow_module,
            workflow_id: workflow_id,
            params: params
          ]
        ]
      },
      restart: :transient
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Detiene un workflow en ejecución.

  Termina gracefully el proceso del workflow especificado.

  ## Parámetros

    * `workflow_id` - Identificador del workflow a detener

  ## Retorno

    * `:ok` - Workflow detenido exitosamente
    * `{:error, :not_found}` - No existe workflow con ese ID

  ## Ejemplo

      iex> stop_workflow("req-123")
      :ok
  """
  @spec stop_workflow(String.t()) :: :ok | {:error, :not_found}
  def stop_workflow(workflow_id) do
    case Beamflow.Engine.Registry.lookup(workflow_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
