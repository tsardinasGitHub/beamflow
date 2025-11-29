defmodule Beamflow.Storage.WorkflowStore do
  @moduledoc """
  Capa de persistencia para workflows usando Amnesia.

  Este módulo proporciona operaciones CRUD para persistir el estado de los
  workflows y su historial de ejecución. Usa transacciones Amnesia para
  garantizar consistencia ACID.

  ## Tablas Amnesia

  - `Beamflow.Database.Workflow` - Estado principal de cada workflow
  - `Beamflow.Database.Event` - Historial de eventos (step completado, fallo, etc.)

  ## Uso

      # Guardar workflow
      {:ok, workflow} = WorkflowStore.save_workflow(actor_state)

      # Obtener workflow
      {:ok, workflow} = WorkflowStore.get_workflow("req-123")

      # Listar workflows por estado
      {:ok, workflows} = WorkflowStore.list_workflows_by_status(:running)

      # Registrar evento
      :ok = WorkflowStore.record_event("req-123", :step_completed, %{step: "ValidateIdentity"})

  ## Migración

  Este módulo fue migrado de Mnesia raw a Amnesia (ver ADR-005).
  La API pública permanece igual para mantener compatibilidad.
  """

  require Logger

  use Amnesia
  alias Beamflow.Database.{Workflow, Event}

  # ============================================================================
  # Tipos
  # ============================================================================

  @typedoc "Registro de workflow persistido"
  @type workflow_record :: %{
          id: String.t(),
          workflow_module: module(),
          status: atom(),
          workflow_state: map(),
          current_step_index: non_neg_integer(),
          total_steps: non_neg_integer(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          error: term() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @typedoc "Registro de evento"
  @type event_record :: %{
          id: String.t(),
          workflow_id: String.t(),
          event_type: atom(),
          data: map(),
          timestamp: DateTime.t()
        }

  # ============================================================================
  # API Pública - Workflows
  # ============================================================================

  @doc """
  Guarda o actualiza un workflow.

  ## Parámetros

    * `actor_state` - Estado del actor del workflow (map completo del GenServer)

  ## Retorno

    * `{:ok, workflow_record}` - Workflow persistido exitosamente
    * `{:error, reason}` - Error al persistir

  ## Ejemplo

      iex> WorkflowStore.save_workflow(%{workflow_id: "req-123", status: :running, ...})
      {:ok, %{id: "req-123", status: :running, ...}}
  """
  @spec save_workflow(map()) :: {:ok, workflow_record()} | {:error, term()}
  def save_workflow(actor_state) do
    now = DateTime.utc_now()

    workflow = %Workflow{
      id: actor_state.workflow_id,
      workflow_module: actor_state.workflow_module,
      status: actor_state.status,
      workflow_state: actor_state.workflow_state,
      current_step_index: actor_state.current_step_index,
      total_steps: actor_state.total_steps,
      started_at: actor_state.started_at,
      completed_at: actor_state.completed_at,
      error: actor_state.error,
      inserted_at: Map.get(actor_state, :inserted_at, now),
      updated_at: now
    }

    Amnesia.transaction do
      Workflow.write(workflow)
    end

    Logger.debug("Workflow #{actor_state.workflow_id} persisted via Amnesia")
    {:ok, workflow_to_map(workflow)}
  rescue
    e ->
      Logger.error("Failed to persist workflow #{actor_state.workflow_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Obtiene un workflow por su ID.

  ## Parámetros

    * `workflow_id` - Identificador único del workflow

  ## Retorno

    * `{:ok, workflow_record}` - Workflow encontrado
    * `{:error, :not_found}` - No existe workflow con ese ID

  ## Ejemplo

      iex> WorkflowStore.get_workflow("req-123")
      {:ok, %{id: "req-123", status: :completed, ...}}
  """
  @spec get_workflow(String.t()) :: {:ok, workflow_record()} | {:error, :not_found}
  def get_workflow(workflow_id) do
    # Usamos dirty read para lecturas rápidas
    case :mnesia.dirty_read(Workflow, workflow_id) do
      [record] when is_tuple(record) ->
        {:ok, tuple_to_workflow_map(record)}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Obtiene un workflow usando transacción (para consistencia estricta).

  Use `get_workflow/1` para lecturas normales. Esta función es útil cuando
  necesita garantizar que lee el valor más reciente en una transacción.

  ## Parámetros

    * `workflow_id` - Identificador único del workflow

  ## Retorno

    * `{:ok, workflow_record}` - Workflow encontrado
    * `{:error, :not_found}` - No existe workflow con ese ID
    * `{:error, reason}` - Error de transacción
  """
  @spec get_workflow_strict(String.t()) :: {:ok, workflow_record()} | {:error, term()}
  def get_workflow_strict(workflow_id) do
    Amnesia.transaction do
      case Workflow.read(workflow_id) do
        nil -> {:error, :not_found}
        workflow -> {:ok, workflow_to_map(workflow)}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Lista todos los workflows, opcionalmente filtrados por estado.

  ## Parámetros

    * `opts` - Opciones de filtrado:
      * `:status` - Filtrar por estado (`:pending`, `:running`, `:completed`, `:failed`)
      * `:limit` - Número máximo de resultados (default: sin límite)

  ## Retorno

    * `{:ok, [workflow_record]}` - Lista de workflows

  ## Ejemplos

      iex> WorkflowStore.list_workflows()
      {:ok, [%{id: "req-123", ...}, %{id: "req-456", ...}]}

      iex> WorkflowStore.list_workflows(status: :running)
      {:ok, [%{id: "req-789", status: :running, ...}]}
  """
  @spec list_workflows(keyword()) :: {:ok, [workflow_record()]}
  def list_workflows(opts \\ []) do
    status_filter = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit)

    Amnesia.transaction do
      workflows =
        Workflow.stream()
        |> Enum.to_list()
        |> List.flatten()
        |> maybe_filter_by_status(status_filter)
        |> Enum.map(&workflow_to_map/1)
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
        |> maybe_limit(limit)

      {:ok, workflows}
    end
  end

  @doc """
  Elimina un workflow.

  También elimina todos los eventos asociados.

  ## Parámetros

    * `workflow_id` - Identificador del workflow a eliminar

  ## Retorno

    * `:ok` - Workflow eliminado exitosamente
    * `{:error, reason}` - Error al eliminar
  """
  @spec delete_workflow(String.t()) :: :ok | {:error, term()}
  def delete_workflow(workflow_id) do
    Amnesia.transaction do
      # Eliminar workflow
      Workflow.delete(workflow_id)

      # Eliminar eventos asociados
      Event.stream()
      |> Enum.to_list()
      |> List.flatten()
      |> Enum.filter(fn e -> e.workflow_id == workflow_id end)
      |> Enum.each(fn event -> Event.delete(event) end)
    end

    Logger.info("Workflow #{workflow_id} and its events deleted")
    :ok
  rescue
    e ->
      Logger.error("Failed to delete workflow #{workflow_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # ============================================================================
  # API Pública - Eventos
  # ============================================================================

  @doc """
  Registra un evento en el historial del workflow.

  ## Parámetros

    * `workflow_id` - ID del workflow
    * `event_type` - Tipo de evento (`:step_started`, `:step_completed`, `:step_failed`, etc.)
    * `data` - Datos adicionales del evento

  ## Retorno

    * `:ok` - Evento registrado exitosamente
    * `{:error, reason}` - Error al registrar

  ## Ejemplo

      iex> WorkflowStore.record_event("req-123", :step_completed, %{step: "ValidateIdentity", duration_ms: 350})
      :ok
  """
  @spec record_event(String.t(), atom(), map()) :: :ok | {:error, term()}
  def record_event(workflow_id, event_type, data \\ %{}) do
    event = Event.new(workflow_id, event_type, data)

    Amnesia.transaction do
      Event.write(event)
    end

    Logger.debug("Event #{event_type} recorded for workflow #{workflow_id}")
    :ok
  rescue
    e ->
      Logger.error("Failed to record event for #{workflow_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Obtiene el historial de eventos de un workflow.

  ## Parámetros

    * `workflow_id` - ID del workflow
    * `opts` - Opciones:
      * `:event_type` - Filtrar por tipo de evento
      * `:limit` - Número máximo de eventos

  ## Retorno

    * `{:ok, [event_record]}` - Lista de eventos ordenados por timestamp

  ## Ejemplo

      iex> WorkflowStore.get_events("req-123")
      {:ok, [
        %{event_type: :step_started, timestamp: ~U[2025-01-01 10:00:00Z], ...},
        %{event_type: :step_completed, timestamp: ~U[2025-01-01 10:00:01Z], ...}
      ]}
  """
  @spec get_events(String.t(), keyword()) :: {:ok, [event_record()]}
  def get_events(workflow_id, opts \\ []) do
    event_type_filter = Keyword.get(opts, :event_type)
    limit = Keyword.get(opts, :limit)

    Amnesia.transaction do
      events =
        Event.stream()
        |> Enum.to_list()
        |> List.flatten()
        |> Enum.filter(fn e -> e.workflow_id == workflow_id end)
        |> maybe_filter_by_event_type(event_type_filter)
        |> Enum.map(&event_to_map/1)
        |> Enum.sort_by(& &1.timestamp, DateTime)
        |> maybe_limit(limit)

      {:ok, events}
    end
  end

  # ============================================================================
  # API Pública - Utilidades
  # ============================================================================

  @doc """
  Cuenta workflows por estado.

  Útil para dashboards y métricas.

  ## Retorno

  Mapa con conteo por estado.

  ## Ejemplo

      iex> WorkflowStore.count_by_status()
      %{pending: 5, running: 12, completed: 156, failed: 3}
  """
  @spec count_by_status() :: map()
  def count_by_status do
    {:ok, all} = list_workflows()

    all
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, workflows} -> {status, length(workflows)} end)
    |> Map.new()
    |> Map.merge(%{pending: 0, running: 0, completed: 0, failed: 0}, fn _k, v1, _v2 -> v1 end)
  end

  @doc """
  Verifica si las tablas Amnesia están disponibles.

  ## Retorno

    * `true` - Tablas disponibles
    * `false` - Tablas no disponibles
  """
  @spec tables_available?() :: boolean()
  def tables_available? do
    tables = :mnesia.system_info(:tables)
    Workflow in tables and Event in tables
  end

  # ============================================================================
  # Funciones Privadas
  # ============================================================================

  # Convierte struct Workflow a map (API compatible)
  defp workflow_to_map(%Workflow{} = w) do
    %{
      id: w.id,
      workflow_module: w.workflow_module,
      status: w.status,
      workflow_state: w.workflow_state,
      current_step_index: w.current_step_index,
      total_steps: w.total_steps,
      started_at: w.started_at,
      completed_at: w.completed_at,
      error: w.error,
      inserted_at: w.inserted_at,
      updated_at: w.updated_at
    }
  end

  # Convierte tupla Mnesia raw a map (para dirty_read)
  defp tuple_to_workflow_map({Workflow, id, workflow_module, status, workflow_state,
                              current_step_index, total_steps, started_at, completed_at,
                              error, inserted_at, updated_at}) do
    %{
      id: id,
      workflow_module: workflow_module,
      status: status,
      workflow_state: workflow_state,
      current_step_index: current_step_index,
      total_steps: total_steps,
      started_at: started_at,
      completed_at: completed_at,
      error: error,
      inserted_at: inserted_at,
      updated_at: updated_at
    }
  end

  # Convierte struct Event a map
  defp event_to_map(%Event{} = e) do
    %{
      id: e.id,
      workflow_id: e.workflow_id,
      event_type: e.event_type,
      data: e.data,
      timestamp: e.timestamp
    }
  end

  defp maybe_filter_by_status(workflows, nil), do: workflows
  defp maybe_filter_by_status(workflows, status) do
    Enum.filter(workflows, fn w -> w.status == status end)
  end

  defp maybe_filter_by_event_type(events, nil), do: events
  defp maybe_filter_by_event_type(events, event_type) do
    Enum.filter(events, fn e -> e.event_type == event_type end)
  end

  defp maybe_limit(list, nil), do: list
  defp maybe_limit(list, limit), do: Enum.take(list, limit)
end
