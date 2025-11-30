defmodule Beamflow.Engine.Retry do
  @moduledoc """
  Sistema de retry automático con backoff exponencial para steps.

  Proporciona políticas de retry configurables que permiten a los steps
  recuperarse de fallos transitorios sin intervención manual.

  ## Filosofía de Diseño

  No todos los errores son iguales. BEAMFlow clasifica errores en 4 categorías:

  | Categoría | Ejemplo | Acción | Retry |
  |-----------|---------|--------|-------|
  | `:transient` | Timeout, 503, rate_limit | Retry automático | ✓ Auto |
  | `:recoverable` | missing_dni, pending_approval | Esperar corrección | ✓ Manual |
  | `:permanent` | fraud_detected, blacklisted | Requiere decisión | ⚠️ Forzar |
  | `:terminal` | system_deprecated, cancelled | Archivar | ✗ Nunca |

  ## Configuración por Step

  Los steps pueden definir su política de retry:

      defmodule MyApp.Steps.SendEmail do
        use Beamflow.Workflows.Step
        use Beamflow.Engine.Retry

        @retry_policy %{
          max_attempts: 5,
          base_delay_ms: 1_000,
          max_delay_ms: 30_000,
          jitter: true,
          retryable_errors: [:timeout, :service_unavailable, :connection_refused]
        }

        @impl true
        def execute(state) do
          # Si falla con :timeout, se reintentará automáticamente
          EmailService.send(state.email, state.content)
        end
      end

  ## Políticas Predefinidas

  - `:aggressive` - 5 intentos, delays cortos (para APIs rápidas)
  - `:conservative` - 3 intentos, delays largos (para servicios lentos)
  - `:patient` - 10 intentos, delays muy largos (para batch jobs)
  - `:none` - Sin retry (fail fast)

  ## Backoff Exponencial

  El delay entre intentos sigue: `min(base * 2^attempt, max) ± jitter`

  ```
  Intento 1: 1s
  Intento 2: 2s
  Intento 3: 4s
  Intento 4: 8s
  Intento 5: 16s (capped at max_delay)
  ```

  ## Integración con Idempotencia

  Cada retry genera una nueva `idempotency_key` con el número de intento,
  permitiendo tracking granular de cada ejecución.

  Ver ADR-004 para detalles de idempotencia.
  """

  require Logger

  alias Beamflow.Engine.CircuitBreaker
  alias Beamflow.Engine.Idempotency

  # ============================================================================
  # Tipos
  # ============================================================================

  @type retry_policy :: %{
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          jitter: boolean(),
          retryable_errors: [atom()] | :all | :transient
        }

  @type retry_state :: %{
          attempt: pos_integer(),
          last_error: term(),
          errors: [term()],
          started_at: DateTime.t(),
          delays: [pos_integer()]
        }

  # ============================================================================
  # Políticas Predefinidas
  # ============================================================================

  @doc """
  Retorna una política de retry predefinida.

  ## Opciones

    * `:aggressive` - 5 intentos, delays cortos (1s-15s)
    * `:conservative` - 3 intentos, delays moderados (2s-30s)
    * `:patient` - 10 intentos, delays largos (5s-300s)
    * `:email` - Optimizada para servicios de email (5 intentos, 2s-60s)
    * `:api` - Para APIs externas (4 intentos, 500ms-10s)
    * `:database` - Para operaciones de DB (3 intentos, 100ms-2s)
    * `:none` - Sin retry (fail fast)

  ## Ejemplo

      policy = Retry.policy(:email)
      # => %{max_attempts: 5, base_delay_ms: 2000, ...}
  """
  @spec policy(atom()) :: retry_policy()
  def policy(:aggressive) do
    %{
      max_attempts: 5,
      base_delay_ms: 1_000,
      max_delay_ms: 15_000,
      jitter: true,
      retryable_errors: :transient
    }
  end

  def policy(:conservative) do
    %{
      max_attempts: 3,
      base_delay_ms: 2_000,
      max_delay_ms: 30_000,
      jitter: true,
      retryable_errors: :transient
    }
  end

  def policy(:patient) do
    %{
      max_attempts: 10,
      base_delay_ms: 5_000,
      max_delay_ms: 300_000,
      jitter: true,
      retryable_errors: :transient
    }
  end

  def policy(:email) do
    %{
      max_attempts: 5,
      base_delay_ms: 2_000,
      max_delay_ms: 60_000,
      jitter: true,
      retryable_errors: [
        :timeout,
        :service_unavailable,
        :connection_refused,
        :smtp_error,
        :rate_limited,
        :temporary_failure
      ]
    }
  end

  def policy(:api) do
    %{
      max_attempts: 4,
      base_delay_ms: 500,
      max_delay_ms: 10_000,
      jitter: true,
      retryable_errors: [
        :timeout,
        :service_unavailable,
        :bad_gateway,
        :gateway_timeout,
        :connection_refused,
        :econnrefused,
        :nxdomain
      ]
    }
  end

  def policy(:database) do
    %{
      max_attempts: 3,
      base_delay_ms: 100,
      max_delay_ms: 2_000,
      jitter: false,
      retryable_errors: [
        :timeout,
        :deadlock,
        :connection_closed,
        :too_many_connections
      ]
    }
  end

  def policy(:payment) do
    %{
      max_attempts: 3,
      base_delay_ms: 1_000,
      max_delay_ms: 10_000,
      jitter: true,
      retryable_errors: [
        :timeout,
        :service_unavailable,
        :gateway_timeout,
        :connection_refused,
        :rate_limited,
        :temporary_failure
      ]
    }
  end

  def policy(:none) do
    %{
      max_attempts: 1,
      base_delay_ms: 0,
      max_delay_ms: 0,
      jitter: false,
      retryable_errors: []
    }
  end

  def policy(custom) when is_map(custom) do
    # Merge con defaults
    Map.merge(policy(:conservative), custom)
  end

  # ============================================================================
  # Ejecución con Retry
  # ============================================================================

  @doc """
  Ejecuta un step con la política de retry especificada.

  ## Parámetros

    * `step_module` - Módulo del step a ejecutar
    * `workflow_state` - Estado actual del workflow
    * `workflow_id` - ID del workflow (para idempotencia)
    * `policy` - Política de retry (átomo o mapa)
    * `opts` - Opciones adicionales

  ## Opciones

    * `:on_retry` - Callback llamado antes de cada retry `fn attempt, delay, error -> :ok end`
    * `:on_exhausted` - Callback cuando se agotan los intentos
    * `:circuit_breaker` - Nombre del circuit breaker a consultar (átomo)

  ## Retorno

    * `{:ok, updated_state, retry_state}` - Éxito después de N intentos
    * `{:error, reason, retry_state}` - Fallo después de agotar intentos

  ## Ejemplo

      case Retry.execute_with_retry(SendEmail, state, "wf-123", :email) do
        {:ok, new_state, %{attempt: 1}} ->
          # Éxito en primer intento
          new_state

        {:ok, new_state, %{attempt: n}} when n > 1 ->
          # Éxito después de retries
          Logger.info("Succeeded after \#{n} attempts")
          new_state

        {:error, reason, retry_state} ->
          # Falló después de todos los intentos
          Logger.error("Failed after \#{retry_state.attempt} attempts: \#{inspect(reason)}")
          handle_permanent_failure(reason, retry_state)
      end
  """
  @spec execute_with_retry(module(), map(), String.t(), atom() | retry_policy(), keyword()) ::
          {:ok, map(), retry_state()} | {:error, term(), retry_state()}
  def execute_with_retry(step_module, workflow_state, workflow_id, policy_or_name, opts \\ [])

  def execute_with_retry(step_module, workflow_state, workflow_id, policy_name, opts)
      when is_atom(policy_name) do
    execute_with_retry(step_module, workflow_state, workflow_id, policy(policy_name), opts)
  end

  def execute_with_retry(step_module, workflow_state, workflow_id, policy, opts)
      when is_map(policy) do
    retry_state = %{
      attempt: 0,
      last_error: nil,
      errors: [],
      started_at: DateTime.utc_now(),
      delays: []
    }

    do_execute_with_retry(step_module, workflow_state, workflow_id, policy, opts, retry_state)
  end

  defp do_execute_with_retry(step_module, workflow_state, workflow_id, policy, opts, retry_state) do
    attempt = retry_state.attempt + 1
    step_name = inspect(step_module)

    # Generar idempotency key para este intento
    idempotency_key = Idempotency.generate_key(workflow_id, step_module, attempt)

    # Verificar idempotencia
    case Idempotency.begin_step(workflow_id, step_module, attempt) do
      {:already_completed, cached_result} ->
        Logger.debug("[Retry] #{step_name} attempt #{attempt}: Using cached result")
        {:ok, cached_result, %{retry_state | attempt: attempt}}

      {:already_pending, _key} ->
        # Pendiente de intento anterior, ejecutar normalmente
        do_attempt(step_module, workflow_state, workflow_id, policy, opts, retry_state, attempt, idempotency_key)

      {:ok, _key} ->
        do_attempt(step_module, workflow_state, workflow_id, policy, opts, retry_state, attempt, idempotency_key)
    end
  end

  defp do_attempt(step_module, workflow_state, workflow_id, policy, opts, retry_state, attempt, idempotency_key) do
    step_name = inspect(step_module)

    # Verificar Circuit Breaker si está configurado
    circuit_breaker = opts[:circuit_breaker]

    if circuit_breaker && not circuit_breaker_allows?(circuit_breaker) do
      Logger.warning("[Retry] #{step_name}: Circuit breaker #{circuit_breaker} is OPEN, failing fast")

      updated_retry_state = %{
        retry_state
        | attempt: attempt,
          last_error: :circuit_open,
          errors: [:circuit_open | retry_state.errors]
      }

      {:error, :circuit_open, updated_retry_state}
    else
      do_execute_attempt(step_module, workflow_state, workflow_id, policy, opts, retry_state, attempt, idempotency_key, circuit_breaker)
    end
  end

  defp do_execute_attempt(step_module, workflow_state, workflow_id, policy, opts, retry_state, attempt, idempotency_key, circuit_breaker) do
    step_name = inspect(step_module)

    # Inyectar información de retry en el estado
    enriched_state =
      workflow_state
      |> Map.put(:idempotency_key, idempotency_key)
      |> Map.put(:retry_attempt, attempt)
      |> Map.put(:max_attempts, policy.max_attempts)

    Logger.debug("[Retry] #{step_name} attempt #{attempt}/#{policy.max_attempts}")

    case step_module.execute(enriched_state) do
      {:ok, updated_state} ->
        # Éxito - marcar como completado
        Idempotency.complete_step(idempotency_key, updated_state)

        # Reportar éxito al circuit breaker
        if circuit_breaker, do: CircuitBreaker.report_success(circuit_breaker)

        final_retry_state = %{retry_state | attempt: attempt}
        {:ok, updated_state, final_retry_state}

      {:error, reason} ->
        # Fallo - evaluar si reintentamos
        Idempotency.fail_step(idempotency_key, reason)

        # Reportar fallo al circuit breaker
        if circuit_breaker, do: CircuitBreaker.report_failure(circuit_breaker, reason)

        updated_retry_state = %{
          retry_state
          | attempt: attempt,
            last_error: reason,
            errors: [reason | retry_state.errors]
        }

        cond do
          # ¿Agotamos intentos?
          attempt >= policy.max_attempts ->
            Logger.warning("[Retry] #{step_name}: Exhausted all #{policy.max_attempts} attempts")
            call_callback(opts[:on_exhausted], [reason, updated_retry_state])
            {:error, reason, updated_retry_state}

          # ¿Es un error retryable?
          not retryable?(reason, policy.retryable_errors) ->
            Logger.warning("[Retry] #{step_name}: Non-retryable error: #{inspect(reason)}")
            {:error, reason, updated_retry_state}

          # Retry!
          true ->
            delay = calculate_delay(attempt, policy)
            updated_retry_state = %{updated_retry_state | delays: [delay | updated_retry_state.delays]}

            Logger.info("[Retry] #{step_name}: Attempt #{attempt} failed, retrying in #{delay}ms...")
            call_callback(opts[:on_retry], [attempt, delay, reason])

            # Esperar con el delay calculado
            Process.sleep(delay)

            # Recursión para siguiente intento
            do_execute_with_retry(step_module, workflow_state, workflow_id, policy, opts, updated_retry_state)
        end
    end
  end

  # ============================================================================
  # Cálculo de Delay
  # ============================================================================

  @doc """
  Calcula el delay para un intento dado usando backoff exponencial.

  ## Fórmula

      delay = min(base_delay * 2^(attempt-1), max_delay) ± jitter

  ## Ejemplo

      calculate_delay(1, %{base_delay_ms: 1000, max_delay_ms: 30000, jitter: true})
      # => ~1000ms

      calculate_delay(3, %{base_delay_ms: 1000, max_delay_ms: 30000, jitter: true})
      # => ~4000ms ± 400ms
  """
  @spec calculate_delay(pos_integer(), retry_policy()) :: pos_integer()
  def calculate_delay(attempt, policy) do
    base = policy.base_delay_ms
    max = policy.max_delay_ms

    # Backoff exponencial: base * 2^(attempt-1)
    exponential = base * :math.pow(2, attempt - 1) |> round()

    # Cap al máximo
    capped = min(exponential, max)

    # Agregar jitter (±10%) para evitar thundering herd
    if policy.jitter do
      jitter_range = round(capped * 0.1)
      jitter = :rand.uniform(jitter_range * 2) - jitter_range
      max(0, capped + jitter)
    else
      capped
    end
  end

  # ============================================================================
  # Clasificación de Errores
  # ============================================================================

  @doc """
  Determina si un error es retryable según la política.
  """
  @spec retryable?(term(), :all | :transient | [atom()]) :: boolean()
  def retryable?(_error, :all), do: true

  def retryable?(error, :transient) do
    error_atom = extract_error_atom(error)

    # Primero verificar si es un error permanente (nunca retryable)
    if permanent_error?(error_atom) do
      false
    else
      error_atom in transient_errors()
    end
  end

  def retryable?(error, retryable_list) when is_list(retryable_list) do
    error_atom = extract_error_atom(error)

    # Errores permanentes nunca son retryable, incluso si están en la lista
    if permanent_error?(error_atom) do
      false
    else
      error_atom in retryable_list
    end
  end

  @doc """
  Lista de errores considerados transitorios (pueden recuperarse con retry).
  """
  @spec transient_errors() :: [atom()]
  def transient_errors do
    [
      :timeout,
      :service_unavailable,
      :bad_gateway,
      :gateway_timeout,
      :connection_refused,
      :connection_closed,
      :econnrefused,
      :econnreset,
      :ehostunreach,
      :enetunreach,
      :nxdomain,
      :temporary_failure,
      :rate_limited,
      :too_many_requests,
      :overloaded,
      # Errores de base de datos transitorios
      :deadlock,
      :lock_timeout,
      :too_many_connections
    ]
  end

  @doc """
  Lista de errores recuperables (requieren corrección externa + retry manual).

  Estos errores pueden resolverse si alguien corrige los datos de entrada
  o completa una acción pendiente. El sistema espera la corrección.

  ## Subcategorías

  - **Datos faltantes**: El usuario puede proveer el dato faltante
  - **Formato inválido**: El usuario puede corregir el formato
  - **Pendientes**: Requieren una acción externa (aprobación, verificación)

  ## Ejemplo

      iex> Retry.recoverable_error?(:missing_dni)
      true

      iex> Retry.recoverable_error?(:fraud_detected)
      false
  """
  @spec recoverable_errors() :: [atom()]
  def recoverable_errors do
    [
      # Errores de validación - datos faltantes (corregibles)
      :missing_dni,
      :missing_email,
      :missing_required_field,
      :missing_applicant_name,
      :missing_vehicle_plate,
      :missing_phone,
      :missing_address,

      # Errores de validación - formato inválido (corregibles)
      :invalid_dni_format,
      :invalid_email_format,
      :invalid_phone_format,
      :invalid_date_format,
      :invalid_input,
      :validation_failed,
      :schema_validation_failed,

      # Errores de autenticación (renovables)
      :token_expired,
      :session_expired,
      :credentials_expired,

      # Errores pendientes de acción externa
      :pending_approval,
      :pending_verification,
      :pending_payment,
      :pending_document,
      :awaiting_confirmation,

      # Errores de configuración (corregibles por admin)
      :invalid_configuration,
      :missing_configuration
    ]
  end

  @doc """
  Lista de errores permanentes (requieren decisión humana, solo retry forzado).

  Estos errores indican decisiones de negocio o violaciones de políticas
  que probablemente no cambiarán. Solo un operador con conocimiento del
  contexto puede decidir si reintentar.

  ## Subcategorías

  - **Seguridad**: Fraude detectado, credenciales inválidas
  - **Reglas de negocio**: Blacklist, límites excedidos
  - **Políticas**: Rechazos por política de la empresa

  ## Ejemplo

      iex> Retry.permanent_error?(:fraud_detected)
      true

      iex> Retry.permanent_error?(:missing_dni)
      false  # Este es :recoverable
  """
  @spec permanent_errors() :: [atom()]
  def permanent_errors do
    [
      # Errores de seguridad (decisión humana requerida)
      :fraud_detected,
      :suspicious_activity,
      :unauthorized,
      :forbidden,
      :invalid_credentials,
      :invalid_token,
      :permission_denied,

      # Errores de reglas de negocio (políticas)
      :applicant_blacklisted,
      :policy_already_exists,
      :duplicate_request,
      :credit_score_too_low,
      :vehicle_not_insurable,
      :request_rejected,
      :max_age_exceeded,
      :coverage_denied,
      :underwriting_rejected
    ]
  end

  @doc """
  Lista de errores terminales (workflow debe archivarse, nunca reintentar).

  Estos errores indican que el workflow no tiene sentido continuar:
  el sistema externo ya no existe, el workflow fue cancelado explícitamente,
  o las condiciones hacen imposible cualquier resolución.

  ## Subcategorías

  - **Sistema**: El sistema/servicio externo fue deprecado o removido
  - **Workflow**: El workflow fue cancelado o expiró
  - **Irreversible**: La operación ya no es posible

  ## Ejemplo

      iex> Retry.terminal_error?(:external_system_deprecated)
      true

      iex> Retry.terminal_error?(:timeout)
      false
  """
  @spec terminal_errors() :: [atom()]
  def terminal_errors do
    [
      # Sistema externo no disponible permanentemente
      :external_system_deprecated,
      :external_system_removed,
      :api_version_unsupported,
      :service_discontinued,
      :provider_terminated,

      # Workflow cancelado o expirado
      :workflow_cancelled,
      :workflow_expired,
      :request_expired,
      :offer_expired,
      :manually_terminated,

      # Errores irreversibles
      :data_corrupted,
      :unrecoverable_state,
      :workflow_not_found,
      :step_not_found,
      :resource_deleted,
      :account_closed
    ]
  end

  @doc """
  Verifica si un error es recuperable (corregible con intervención externa).

  ## Ejemplo

      iex> Retry.recoverable_error?(:missing_dni)
      true

      iex> Retry.recoverable_error?(:fraud_detected)
      false
  """
  @spec recoverable_error?(term()) :: boolean()
  def recoverable_error?(error) do
    error_atom = extract_error_atom(error)
    error_atom in recoverable_errors()
  end

  @doc """
  Verifica si un error es permanente (requiere decisión humana para retry).

  ## Ejemplo

      iex> Retry.permanent_error?(:fraud_detected)
      true

      iex> Retry.permanent_error?(:missing_dni)
      false  # Este es recoverable, no permanent

      iex> Retry.permanent_error?({:fraud_detected, "Score de riesgo alto"})
      true
  """
  @spec permanent_error?(term()) :: boolean()
  def permanent_error?(error) do
    error_atom = extract_error_atom(error)
    error_atom in permanent_errors()
  end

  @doc """
  Verifica si un error es terminal (workflow debe archivarse).

  ## Ejemplo

      iex> Retry.terminal_error?(:external_system_deprecated)
      true

      iex> Retry.terminal_error?(:timeout)
      false
  """
  @spec terminal_error?(term()) :: boolean()
  def terminal_error?(error) do
    error_atom = extract_error_atom(error)
    error_atom in terminal_errors()
  end

  @doc """
  Verifica si un error permite retry automático.

  Solo errores `:transient` permiten retry automático.
  Los `:recoverable` requieren corrección + retry manual.
  Los `:permanent` requieren confirmación explícita.
  Los `:terminal` nunca se reintentan.

  ## Ejemplo

      iex> Retry.auto_retryable?(:timeout)
      true

      iex> Retry.auto_retryable?(:missing_dni)
      false  # Requiere corrección manual
  """
  @spec auto_retryable?(term()) :: boolean()
  def auto_retryable?(error) do
    classify_error(error) == :transient
  end

  @doc """
  Verifica si un error permite retry manual (después de corrección).

  Errores `:transient`, `:recoverable` y `:unknown` permiten retry manual.
  Errores `:permanent` permiten retry forzado (con confirmación).
  Errores `:terminal` nunca permiten retry.

  ## Ejemplo

      iex> Retry.manual_retryable?(:missing_dni)
      true

      iex> Retry.manual_retryable?(:external_system_deprecated)
      false
  """
  @spec manual_retryable?(term()) :: boolean()
  def manual_retryable?(error) do
    classify_error(error) not in [:terminal]
  end

  @doc """
  Retorna información detallada sobre la clasificación de un error.

  Útil para mostrar en la UI qué acciones están disponibles.

  ## Ejemplo

      iex> Retry.error_info(:missing_dni)
      %{
        class: :recoverable,
        auto_retry: false,
        manual_retry: true,
        force_retry: false,
        action: :wait_for_correction,
        message: "Este error requiere corrección de datos. Una vez corregido, puede reintentarse manualmente."
      }
  """
  @spec error_info(term()) :: map()
  def error_info(error) do
    class = classify_error(error)

    case class do
      :transient ->
        %{
          class: :transient,
          auto_retry: true,
          manual_retry: true,
          force_retry: false,
          action: :auto_retry,
          message: "Error temporal. El sistema reintentará automáticamente.",
          icon: "🔄",
          color: "blue"
        }

      :recoverable ->
        %{
          class: :recoverable,
          auto_retry: false,
          manual_retry: true,
          force_retry: false,
          action: :wait_for_correction,
          message: "Requiere corrección de datos. Una vez corregido, puede reintentarse.",
          icon: "✏️",
          color: "yellow"
        }

      :permanent ->
        %{
          class: :permanent,
          auto_retry: false,
          manual_retry: false,
          force_retry: true,
          action: :requires_decision,
          message: "Requiere decisión humana. Solo un operador puede forzar el reintento.",
          icon: "⚠️",
          color: "orange"
        }

      :terminal ->
        %{
          class: :terminal,
          auto_retry: false,
          manual_retry: false,
          force_retry: false,
          action: :archive,
          message: "Este workflow no puede continuar y será archivado.",
          icon: "🚫",
          color: "red"
        }

      :unknown ->
        %{
          class: :unknown,
          auto_retry: true,
          manual_retry: true,
          force_retry: false,
          action: :auto_retry,
          message: "Error no clasificado. Se tratará como temporal.",
          icon: "❓",
          color: "gray"
        }
    end
  end

  @typedoc """
  Categorías de clasificación de errores.

  - `:transient` - Retry automático (timeout, service_unavailable)
  - `:recoverable` - Espera corrección externa + retry manual (missing_dni, pending_approval)
  - `:permanent` - Requiere decisión humana, solo retry forzado (fraud_detected, blacklisted)
  - `:terminal` - Nunca reintentar, archivar (system_deprecated, workflow_cancelled)
  - `:unknown` - No clasificado, se trata como transient por defecto
  """
  @type error_class :: :transient | :recoverable | :permanent | :terminal | :unknown

  @doc """
  Clasifica un error en una de las 4 categorías.

  ## Categorías

  | Categoría | Acción | Ejemplo |
  |-----------|--------|---------|  
  | `:transient` | Retry automático | timeout, rate_limited |
  | `:recoverable` | Esperar corrección + retry manual | missing_dni, pending_approval |
  | `:permanent` | Solo retry forzado con confirmación | fraud_detected, blacklisted |
  | `:terminal` | Archivar, nunca reintentar | system_deprecated |

  ## Ejemplo

      iex> Retry.classify_error(:timeout)
      :transient

      iex> Retry.classify_error(:missing_dni)
      :recoverable

      iex> Retry.classify_error(:fraud_detected)
      :permanent

      iex> Retry.classify_error(:external_system_deprecated)
      :terminal

      iex> Retry.classify_error(:some_unknown_error)
      :unknown
  """
  @spec classify_error(term()) :: error_class()
  def classify_error(error) do
    error_atom = extract_error_atom(error)

    cond do
      error_atom in terminal_errors() -> :terminal
      error_atom in permanent_errors() -> :permanent
      error_atom in recoverable_errors() -> :recoverable
      error_atom in transient_errors() -> :transient
      true -> :unknown
    end
  end

  defp extract_error_atom(error) when is_atom(error), do: error
  defp extract_error_atom({error, _}) when is_atom(error), do: error
  defp extract_error_atom({error, _, _}) when is_atom(error), do: error
  defp extract_error_atom(%{type: type}) when is_atom(type), do: type
  defp extract_error_atom(%{reason: reason}) when is_atom(reason), do: reason
  defp extract_error_atom(_), do: :unknown

  # ============================================================================
  # Circuit Breaker Integration
  # ============================================================================

  defp circuit_breaker_allows?(breaker_name) do
    CircuitBreaker.allow?(breaker_name)
  end

  # ============================================================================
  # Utilidades
  # ============================================================================

  defp call_callback(nil, _args), do: :ok
  defp call_callback(callback, args) when is_function(callback), do: apply(callback, args)

  @doc """
  Macro para agregar configuración de retry a un step.

  ## Uso

      defmodule MyStep do
        use Beamflow.Engine.Retry, policy: :email

        # o con configuración custom
        use Beamflow.Engine.Retry,
          max_attempts: 5,
          base_delay_ms: 2_000,
          retryable_errors: [:timeout, :smtp_error]
      end
  """
  defmacro __using__(opts) do
    quote do
      @retry_policy Beamflow.Engine.Retry.build_policy(unquote(opts))

      def __retry_policy__, do: @retry_policy
    end
  end

  @doc false
  def build_policy(opts) do
    case Keyword.get(opts, :policy) do
      nil -> policy(Map.new(opts))
      name when is_atom(name) -> policy(name)
      custom -> policy(custom)
    end
  end
end
