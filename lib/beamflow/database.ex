require Amnesia
use Amnesia

defdatabase Beamflow.Database do
  @moduledoc """
  Definición de la base de datos Amnesia para Beamflow.

  Este módulo define todas las tablas y sus estructuras usando el DSL de Amnesia,
  proporcionando una capa de abstracción limpia sobre Mnesia.

  ## Tablas

  | Tabla | Propósito | Tipo |
  |-------|-----------|------|
  | Workflow | Estado de cada workflow | `:set` (único por ID) |
  | Event | Historial de eventos | `:bag` (múltiples por workflow) |
  | Idempotency | Control de ejecución única | `:set` |
  | DeadLetterEntry | Workflows fallidos para reproceso | `:set` |

  ## Uso

      # Crear tablas (desarrollo)
      Beamflow.Database.create(disk: [node()])

      # Usar en transacciones
      use Beamflow.Database

      Amnesia.transaction do
        %Workflow{id: "wf-123", status: :running}
        |> Workflow.write()
      end

  ## Migración

  Para cambios de schema:

      Beamflow.Database.Migration.migrate()

  Ver `ADR-005` para justificación de Amnesia.
  """

  # ============================================================================
  # Tabla: Workflow
  # Estado principal de cada workflow ejecutado
  # ============================================================================

  deftable Workflow,
    [:id, :workflow_module, :status, :workflow_state, :current_step_index,
     :total_steps, :started_at, :completed_at, :error, :inserted_at, :updated_at],
    type: :set,
    index: [:status, :workflow_module] do

    @type t :: %__MODULE__{
      id: String.t(),
      workflow_module: module(),
      status: :pending | :running | :completed | :failed | :compensating,
      workflow_state: map(),
      current_step_index: non_neg_integer(),
      total_steps: non_neg_integer(),
      started_at: DateTime.t() | nil,
      completed_at: DateTime.t() | nil,
      error: term() | nil,
      inserted_at: DateTime.t(),
      updated_at: DateTime.t()
    }

    @doc """
    Crea un nuevo registro de workflow.
    """
    @spec new(map()) :: t()
    def new(attrs) do
      now = DateTime.utc_now()

      %__MODULE__{
        id: attrs[:id] || attrs["id"],
        workflow_module: attrs[:workflow_module] || attrs["workflow_module"],
        status: attrs[:status] || :pending,
        workflow_state: attrs[:workflow_state] || %{},
        current_step_index: attrs[:current_step_index] || 0,
        total_steps: attrs[:total_steps] || 0,
        started_at: attrs[:started_at],
        completed_at: attrs[:completed_at],
        error: attrs[:error],
        inserted_at: attrs[:inserted_at] || now,
        updated_at: attrs[:updated_at] || now
      }
    end

    @doc """
    Actualiza un workflow existente.
    """
    @spec update(t(), map()) :: t()
    def update(workflow, attrs) do
      workflow
      |> Map.merge(Map.new(attrs))
      |> Map.put(:updated_at, DateTime.utc_now())
    end
  end

  # Implementación de Jason.Encoder para Workflow
  defimpl Jason.Encoder, for: [Workflow] do
    def encode(struct, opts) do
      %{
        "id" => struct.id,
        "workflow_module" => inspect(struct.workflow_module),
        "status" => struct.status,
        "workflow_state" => struct.workflow_state,
        "current_step_index" => struct.current_step_index,
        "total_steps" => struct.total_steps,
        "started_at" => struct.started_at,
        "completed_at" => struct.completed_at,
        "error" => if(struct.error, do: inspect(struct.error), else: nil),
        "inserted_at" => struct.inserted_at,
        "updated_at" => struct.updated_at
      }
      |> Jason.Encode.map(opts)
    end
  end

  # ============================================================================
  # Tabla: Event
  # Historial de eventos por workflow (audit trail)
  # ============================================================================

  deftable Event,
    [:id, :workflow_id, :event_type, :data, :timestamp],
    type: :bag,
    index: [:workflow_id, :event_type] do

    @type event_type ::
      :workflow_started | :workflow_completed | :workflow_failed |
      :step_started | :step_completed | :step_failed |
      :compensation_started | :compensation_completed | :compensation_failed |
      :retry_scheduled | :dlq_enqueued

    @type t :: %__MODULE__{
      id: String.t(),
      workflow_id: String.t(),
      event_type: event_type(),
      data: map(),
      timestamp: DateTime.t()
    }

    @doc """
    Crea un nuevo evento.
    """
    @spec new(String.t(), event_type(), map()) :: t()
    def new(workflow_id, event_type, data \\ %{}) do
      %__MODULE__{
        id: UUID.uuid4(),
        workflow_id: workflow_id,
        event_type: event_type,
        data: data,
        timestamp: DateTime.utc_now()
      }
    end
  end

  defimpl Jason.Encoder, for: [Event] do
    def encode(struct, opts) do
      %{
        "id" => struct.id,
        "workflow_id" => struct.workflow_id,
        "event_type" => struct.event_type,
        "data" => struct.data,
        "timestamp" => struct.timestamp
      }
      |> Jason.Encode.map(opts)
    end
  end

  # ============================================================================
  # Tabla: Idempotency
  # Control de ejecución exactamente-una-vez para steps
  # ============================================================================

  deftable Idempotency,
    [:key, :status, :started_at, :completed_at, :result, :error],
    type: :set,
    index: [:status] do

    @type status :: :pending | :completed | :failed

    @type t :: %__MODULE__{
      key: String.t(),          # "{workflow_id}:{step}:{attempt}"
      status: status(),
      started_at: DateTime.t(),
      completed_at: DateTime.t() | nil,
      result: map() | nil,
      error: term() | nil
    }

    @doc """
    Crea un registro de idempotencia pendiente.
    """
    @spec pending(String.t()) :: t()
    def pending(key) do
      %__MODULE__{
        key: key,
        status: :pending,
        started_at: DateTime.utc_now(),
        completed_at: nil,
        result: nil,
        error: nil
      }
    end

    @doc """
    Marca como completado.
    """
    @spec complete(t(), map()) :: t()
    def complete(record, result) do
      %{record |
        status: :completed,
        completed_at: DateTime.utc_now(),
        result: result
      }
    end

    @doc """
    Marca como fallido.
    """
    @spec fail(t(), term()) :: t()
    def fail(record, error) do
      %{record |
        status: :failed,
        completed_at: DateTime.utc_now(),
        error: error
      }
    end
  end

  defimpl Jason.Encoder, for: [Idempotency] do
    def encode(struct, opts) do
      %{
        "key" => struct.key,
        "status" => struct.status,
        "started_at" => struct.started_at,
        "completed_at" => struct.completed_at,
        "result" => struct.result,
        "error" => if(struct.error, do: inspect(struct.error), else: nil)
      }
      |> Jason.Encode.map(opts)
    end
  end

  # ============================================================================
  # Tabla: DeadLetterEntry
  # Workflows fallidos para reprocesamiento
  # ============================================================================

  deftable DeadLetterEntry,
    [:id, :type, :status, :workflow_id, :workflow_module, :failed_step,
     :error, :error_class, :context, :original_params, :metadata, :created_at, :updated_at,
     :retry_count, :next_retry_at, :resolution],
    type: :set,
    index: [:status, :type, :workflow_id, :error_class] do

    @type entry_type :: :workflow_failed | :compensation_failed | :critical_failure
    @type entry_status :: :pending | :retrying | :resolved | :abandoned | :archived
    @type error_class :: :transient | :recoverable | :permanent | :terminal | :unknown

    @type t :: %__MODULE__{
      id: String.t(),
      type: entry_type(),
      status: entry_status(),
      workflow_id: String.t(),
      workflow_module: module(),
      failed_step: module() | nil,
      error: term(),
      error_class: error_class(),
      context: map(),
      original_params: map(),
      metadata: map(),
      created_at: DateTime.t(),
      updated_at: DateTime.t(),
      retry_count: non_neg_integer(),
      next_retry_at: DateTime.t() | nil,
      resolution: map() | nil
    }

    @doc """
    Crea una nueva entrada DLQ.

    Automáticamente clasifica el error en una de 4 categorías:

    ## Error Classes

    | Clase | Acción | Retry |
    |-------|--------|-------|
    | `:transient` | Retry automático | ✓ Auto |
    | `:recoverable` | Esperar corrección | ✓ Manual |
    | `:permanent` | Decisión humana | ⚠️ Forzar |
    | `:terminal` | Archivar | ✗ Nunca |
    """
    @spec new(map()) :: t()
    def new(attrs) do
      now = DateTime.utc_now()
      error = attrs[:error]
      error_class = classify_error(error)

      # Solo calcular next_retry para errores transitorios (retry automático)
      # recoverable, permanent y terminal no tienen retry automático
      next_retry = if error_class == :transient, do: calculate_next_retry(0), else: nil

      # Status inicial depende de la clase de error
      initial_status = if error_class == :terminal, do: :archived, else: :pending

      %__MODULE__{
        id: generate_id(),
        type: attrs[:type],
        status: initial_status,
        workflow_id: attrs[:workflow_id],
        workflow_module: attrs[:workflow_module],
        failed_step: attrs[:failed_step],
        error: error,
        error_class: error_class,
        context: sanitize(attrs[:context] || %{}),
        original_params: sanitize(attrs[:original_params] || %{}),
        metadata: attrs[:metadata] || %{},
        created_at: now,
        updated_at: now,
        retry_count: 0,
        next_retry_at: next_retry,
        resolution: nil
      }
    end

    @doc """
    Verifica si esta entrada permite retry automático.

    Solo errores `:transient` y `:unknown` permiten retry automático.
    """
    @spec auto_retryable?(t()) :: boolean()
    def auto_retryable?(%__MODULE__{error_class: class}) when class in [:transient, :unknown], do: true
    def auto_retryable?(%__MODULE__{}), do: false

    @doc """
    Verifica si esta entrada permite retry manual (después de corrección).

    Errores `:transient`, `:recoverable` y `:unknown` permiten retry manual.
    """
    @spec manual_retryable?(t()) :: boolean()
    def manual_retryable?(%__MODULE__{error_class: :terminal}), do: false
    def manual_retryable?(%__MODULE__{error_class: :permanent}), do: false
    def manual_retryable?(%__MODULE__{}), do: true

    @doc """
    Verifica si esta entrada permite retry forzado (con confirmación).

    Errores `:permanent` permiten retry forzado por un operador.
    Errores `:terminal` nunca permiten retry.
    """
    @spec force_retryable?(t()) :: boolean()
    def force_retryable?(%__MODULE__{error_class: :permanent}), do: true
    def force_retryable?(%__MODULE__{error_class: :terminal}), do: false
    def force_retryable?(%__MODULE__{}), do: true

    @doc """
    Verifica si esta entrada es reintentable de alguna forma.

    Retorna `false` solo para errores `:terminal`.
    """
    @spec retryable?(t()) :: boolean()
    def retryable?(%__MODULE__{error_class: :terminal}), do: false
    def retryable?(%__MODULE__{}), do: true

    # Clasifica el error para determinar si es reintentable
    defp classify_error(error) do
      try do
        Beamflow.Engine.Retry.classify_error(error)
      rescue
        _ -> basic_classify_error(error)
      end
    end

    # Clasificación básica de errores (fallback durante compilación)
    defp basic_classify_error(error) when is_atom(error) do
      terminal = [
        :external_system_deprecated, :workflow_cancelled, :workflow_expired,
        :data_corrupted, :unrecoverable_state
      ]

      permanent = [
        :fraud_detected, :applicant_blacklisted, :unauthorized, :forbidden,
        :duplicate_request, :credit_score_too_low
      ]

      recoverable = [
        :missing_dni, :missing_email, :missing_required_field,
        :invalid_dni_format, :invalid_email_format, :invalid_input,
        :validation_failed, :pending_approval, :pending_verification
      ]

      transient = [
        :timeout, :service_unavailable, :connection_refused,
        :rate_limited, :temporary_failure
      ]

      cond do
        error in terminal -> :terminal
        error in permanent -> :permanent
        error in recoverable -> :recoverable
        error in transient -> :transient
        true -> :unknown
      end
    end

    defp basic_classify_error({error, _}) when is_atom(error) do
      basic_classify_error(error)
    end

    defp basic_classify_error(_), do: :unknown

    defp generate_id do
      "dlq_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
    end

    defp sanitize(data) when is_map(data) do
      data
      |> Map.drop([:password, :card_number, :cvv, :pin, :secret])
      |> Map.new(fn {k, v} -> {k, truncate_if_needed(v)} end)
    end

    defp truncate_if_needed(v) when is_binary(v) and byte_size(v) > 1000 do
      String.slice(v, 0, 1000) <> "... [truncated]"
    end
    defp truncate_if_needed(v), do: v

    defp calculate_next_retry(retry_count) do
      base_minutes = 5
      max_minutes = 720
      delay = min(base_minutes * :math.pow(3, retry_count), max_minutes) |> round()
      DateTime.add(DateTime.utc_now(), delay * 60, :second)
    end

    @doc """
    Incrementa contador de retry y calcula próximo intento.
    """
    @spec increment_retry(t()) :: t()
    def increment_retry(entry) do
      new_count = entry.retry_count + 1
      %{entry |
        status: :retrying,
        retry_count: new_count,
        updated_at: DateTime.utc_now(),
        next_retry_at: calculate_next_retry(new_count)
      }
    end

    @doc """
    Marca entrada como resuelta.
    """
    @spec resolve(t(), atom(), String.t() | nil) :: t()
    def resolve(entry, resolution_type, notes) do
      status = if resolution_type == :abandoned, do: :abandoned, else: :resolved

      %{entry |
        status: status,
        updated_at: DateTime.utc_now(),
        resolution: %{
          type: resolution_type,
          notes: notes,
          resolved_at: DateTime.utc_now()
        }
      }
    end
  end

  defimpl Jason.Encoder, for: [DeadLetterEntry] do
    def encode(struct, opts) do
      %{
        "id" => struct.id,
        "type" => struct.type,
        "status" => struct.status,
        "workflow_id" => struct.workflow_id,
        "workflow_module" => inspect(struct.workflow_module),
        "failed_step" => if(struct.failed_step, do: inspect(struct.failed_step), else: nil),
        "error" => inspect(struct.error),
        "context" => struct.context,
        "original_params" => struct.original_params,
        "metadata" => struct.metadata,
        "created_at" => struct.created_at,
        "updated_at" => struct.updated_at,
        "retry_count" => struct.retry_count,
        "next_retry_at" => struct.next_retry_at,
        "resolution" => struct.resolution
      }
      |> Jason.Encode.map(opts)
    end
  end
end
