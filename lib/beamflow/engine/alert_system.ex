defmodule Beamflow.Engine.AlertSystem do
  @moduledoc """
  Sistema de alertas para eventos críticos en BEAMFlow.

  ## Severidades

  | Nivel | Descripción | Ejemplo | Acción |
  |-------|-------------|---------|--------|
  | `:critical` | Requiere acción inmediata | Compensación fallida | Página a on-call |
  | `:high` | Importante pero no urgente | DLQ entry creada | Notificar equipo |
  | `:medium` | Informativo con atención | Workflow fallido | Log + métricas |
  | `:low` | Puramente informativo | Circuit breaker abierto | Solo métricas |

  ## Canales de Notificación

  El sistema soporta múltiples canales configurables:

  - **Logger**: Siempre activo, registra en logs de Elixir
  - **PubSub**: Broadcast a suscriptores internos
  - **Webhook**: POST a URL configurada (Slack, PagerDuty, etc.)
  - **Email**: Para alertas críticas
  - **Metrics**: Contadores para Prometheus/Telemetry

  ## Configuración

      config :beamflow, Beamflow.Engine.AlertSystem,
        channels: [:logger, :pubsub, :webhook],
        webhook_url: "https://hooks.slack.com/...",
        critical_email: "oncall@company.com",
        rate_limit: 60_000  # ms entre alertas duplicadas

  ## Uso

      AlertSystem.send_alert(%{
        severity: :critical,
        type: :compensation_failed,
        title: "Payment Refund Failed",
        message: "Could not refund tx_123 after 5 attempts",
        metadata: %{workflow_id: "wf-456", amount: 99.99}
      })

  ## Rate Limiting

  Alertas idénticas se suprimen durante el período configurado
  para evitar flooding durante incidentes.
  """

  use GenServer

  require Logger

  @default_rate_limit :timer.minutes(1)

  # ============================================================================
  # Types
  # ============================================================================

  @type severity :: :critical | :high | :medium | :low
  @type channel :: :logger | :pubsub | :webhook | :email | :metrics

  @type alert :: %{
          severity: severity(),
          type: atom(),
          title: String.t(),
          message: String.t(),
          metadata: map()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the Alert System.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sends an alert through all configured channels.

  ## Parameters

    * `alert` - Map with:
      * `:severity` - Required. One of `:critical`, `:high`, `:medium`, `:low`
      * `:type` - Required. Atom identifying the alert type
      * `:title` - Required. Short title
      * `:message` - Required. Detailed message
      * `:metadata` - Optional. Additional data

  ## Examples

      AlertSystem.send_alert(%{
        severity: :high,
        type: :circuit_breaker_opened,
        title: "Circuit Breaker Opened",
        message: "Payment gateway circuit breaker opened after 3 failures",
        metadata: %{service: :payment_gateway, failures: 3}
      })
  """
  @spec send_alert(alert()) :: :ok
  def send_alert(alert) do
    GenServer.cast(__MODULE__, {:alert, enrich_alert(alert)})
  end

  @doc """
  Sends a critical alert that bypasses rate limiting.

  Use sparingly - only for truly critical situations.
  """
  @spec send_critical(String.t(), String.t(), map()) :: :ok
  def send_critical(title, message, metadata \\ %{}) do
    send_alert(%{
      severity: :critical,
      type: :critical_alert,
      title: title,
      message: message,
      metadata: Map.put(metadata, :bypass_rate_limit, true)
    })
  end

  @doc """
  Gets recent alerts from the buffer.

  ## Options

    * `:severity` - Filter by severity
    * `:type` - Filter by type
    * `:limit` - Maximum number to return (default: 100)
    * `:since` - Only alerts after this DateTime
  """
  @spec recent_alerts(keyword()) :: [map()]
  def recent_alerts(opts \\ []) do
    GenServer.call(__MODULE__, {:recent, opts})
  end

  @doc """
  Gets alert statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Subscribes to alerts via PubSub.

  Alerts will be sent as `{:alert, alert}` messages.
  """
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(Beamflow.PubSub, "alerts")
  end

  @doc """
  Subscribes to alerts of a specific severity.
  """
  @spec subscribe(severity()) :: :ok
  def subscribe(severity) when severity in [:critical, :high, :medium, :low] do
    Phoenix.PubSub.subscribe(Beamflow.PubSub, "alerts:#{severity}")
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    config = Application.get_env(:beamflow, __MODULE__, [])

    state = %{
      channels: Keyword.get(config, :channels, [:logger, :pubsub]),
      webhook_url: Keyword.get(config, :webhook_url),
      critical_email: Keyword.get(config, :critical_email),
      rate_limit: Keyword.get(config, :rate_limit, @default_rate_limit),
      # Rate limit tracking: %{alert_key => last_sent_at}
      sent_alerts: %{},
      # Ring buffer for recent alerts
      recent_buffer: :queue.new(),
      buffer_size: Keyword.get(opts, :buffer_size, 1000),
      # Statistics
      stats: %{
        total_sent: 0,
        by_severity: %{critical: 0, high: 0, medium: 0, low: 0},
        by_type: %{},
        rate_limited: 0
      }
    }

    Logger.info("AlertSystem started with channels: #{inspect(state.channels)}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:alert, alert}, state) do
    alert_key = generate_alert_key(alert)
    bypass_rate_limit = alert.metadata[:bypass_rate_limit] == true

    cond do
      # Check rate limit (unless bypassed)
      not bypass_rate_limit and rate_limited?(alert_key, state) ->
        Logger.debug("AlertSystem: Rate limited alert #{alert_key}")
        new_stats = update_in(state.stats, [:rate_limited], &(&1 + 1))
        {:noreply, %{state | stats: new_stats}}

      true ->
        # Send through all channels
        Enum.each(state.channels, fn channel ->
          send_to_channel(channel, alert, state)
        end)

        # Update state
        new_state =
          state
          |> record_sent_alert(alert_key)
          |> add_to_buffer(alert)
          |> update_stats(alert)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call({:recent, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    severity_filter = Keyword.get(opts, :severity)
    type_filter = Keyword.get(opts, :type)

    alerts =
      :queue.to_list(state.recent_buffer)
      |> Enum.filter(fn alert ->
        severity_match = severity_filter == nil or alert.severity == severity_filter
        type_match = type_filter == nil or alert.type == type_filter
        severity_match and type_match
      end)
      |> Enum.take(limit)

    {:reply, alerts, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp enrich_alert(alert) do
    alert
    |> Map.put_new(:metadata, %{})
    |> Map.put(:id, generate_alert_id())
    |> Map.put(:timestamp, DateTime.utc_now())
    |> Map.put(:node, node())
  end

  defp generate_alert_id do
    "alert_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp generate_alert_key(alert) do
    # Key basado en tipo y metadata relevante (no timestamp)
    :erlang.phash2({alert.type, alert.severity, Map.drop(alert.metadata, [:timestamp, :bypass_rate_limit])})
  end

  defp rate_limited?(alert_key, state) do
    case Map.get(state.sent_alerts, alert_key) do
      nil ->
        false

      last_sent ->
        elapsed = DateTime.diff(DateTime.utc_now(), last_sent, :millisecond)
        elapsed < state.rate_limit
    end
  end

  defp record_sent_alert(state, alert_key) do
    new_sent = Map.put(state.sent_alerts, alert_key, DateTime.utc_now())

    # Limpiar alertas antiguas (más de 1 hora)
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
    cleaned =
      Enum.filter(new_sent, fn {_, time} ->
        DateTime.compare(time, one_hour_ago) == :gt
      end)
      |> Map.new()

    %{state | sent_alerts: cleaned}
  end

  defp add_to_buffer(state, alert) do
    new_buffer = :queue.in(alert, state.recent_buffer)

    # Mantener tamaño del buffer
    trimmed_buffer =
      if :queue.len(new_buffer) > state.buffer_size do
        {_, q} = :queue.out(new_buffer)
        q
      else
        new_buffer
      end

    %{state | recent_buffer: trimmed_buffer}
  end

  defp update_stats(state, alert) do
    new_stats =
      state.stats
      |> update_in([:total_sent], &(&1 + 1))
      |> update_in([:by_severity, alert.severity], &((&1 || 0) + 1))
      |> update_in([:by_type, alert.type], &((&1 || 0) + 1))

    %{state | stats: new_stats}
  end

  # ============================================================================
  # Channel Handlers
  # ============================================================================

  defp send_to_channel(:logger, alert, _state) do
    log_level =
      case alert.severity do
        :critical -> :error
        :high -> :warning
        :medium -> :info
        :low -> :debug
      end

    Logger.log(log_level, fn ->
      "[ALERT #{alert.severity}] #{alert.title}: #{alert.message} | #{inspect(alert.metadata)}"
    end)
  end

  defp send_to_channel(:pubsub, alert, _state) do
    # Broadcast general
    Phoenix.PubSub.broadcast(Beamflow.PubSub, "alerts", {:alert, alert})

    # Broadcast por severidad
    Phoenix.PubSub.broadcast(Beamflow.PubSub, "alerts:#{alert.severity}", {:alert, alert})
  end

  defp send_to_channel(:webhook, alert, state) do
    if state.webhook_url do
      spawn(fn ->
        send_webhook(state.webhook_url, alert)
      end)
    end
  end

  defp send_to_channel(:email, alert, state) do
    if alert.severity == :critical and state.critical_email do
      spawn(fn ->
        send_email_alert(state.critical_email, alert)
      end)
    end
  end

  defp send_to_channel(:metrics, alert, _state) do
    # Emitir telemetría para Prometheus/métricas
    :telemetry.execute(
      [:beamflow, :alert],
      %{count: 1},
      %{severity: alert.severity, type: alert.type}
    )
  end

  defp send_to_channel(channel, _alert, _state) do
    Logger.warning("AlertSystem: Unknown channel #{inspect(channel)}")
  end

  defp send_webhook(url, alert) do
    payload = %{
      severity: alert.severity,
      type: alert.type,
      title: alert.title,
      message: alert.message,
      metadata: alert.metadata,
      timestamp: alert.timestamp,
      node: alert.node
    }

    case Req.post(url, json: payload, receive_timeout: 5000) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.debug("AlertSystem: Webhook sent successfully")

      {:ok, %{status: status}} ->
        Logger.warning("AlertSystem: Webhook returned status #{status}")

      {:error, reason} ->
        Logger.error("AlertSystem: Webhook failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error("AlertSystem: Webhook error: #{Exception.message(e)}")
  end

  defp send_email_alert(to, alert) do
    # Simulación - en producción usar Bamboo, Swoosh, etc.
    Logger.info("""
    📧 [SIMULATED CRITICAL EMAIL]
    To: #{to}
    Subject: 🚨 CRITICAL: #{alert.title}
    Body: #{alert.message}
    Metadata: #{inspect(alert.metadata)}
    """)
  end
end
