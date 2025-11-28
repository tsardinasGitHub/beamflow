defmodule Beamflow.Domains.Insurance.Steps.SendConfirmationEmail do
  @moduledoc """
  Step 5: Enviar email de notificación con el veredicto de la solicitud.

  Este step envía un email diferente según el resultado de la evaluación:
  - **Aprobado**: Email de bienvenida con número de póliza
  - **Rechazado**: Email de notificación con razón del rechazo

  ## Retry Automático con Backoff

  Este step usa la política de retry `:email` que proporciona:
  - 5 intentos máximos
  - Backoff exponencial: 2s → 4s → 8s → 16s → 32s (max 60s)
  - Errores retryables: timeout, service_unavailable, smtp_error, etc.

  Si el servicio de email está caído temporalmente, el step reintentará
  automáticamente sin intervención manual.

  ## Idempotencia Transparente (Centralizada)

  Este step **NO necesita manejar idempotencia manualmente**. El `WorkflowActor`
  lo hace de forma centralizada en 3 fases:

  1. **BEFORE**: Verifica si el step ya completó (cache hit → skip)
  2. **DURING**: Inyecta `idempotency_key` en el estado para servicios externos
  3. **AFTER**: Registra resultado para futuras recuperaciones

  ## Uso de la Idempotency Key

  El estado recibido incluye `idempotency_key` que puede usarse en llamadas
  a servicios externos que soporten deduplicación:

  ```elixir
  def execute(%{idempotency_key: key} = state) do
    EmailService.send(
      to: state.email,
      idempotency_key: key  # El servicio usa esto para deduplicar
    )
  end
  ```

  ## Diseño: Steps Atómicos vs Checkpoints

  Este step sigue el principio de **atomicidad**:

  > "Un step = una operación atómica con un solo side-effect externo"

  Si necesitáramos enviar múltiples emails (ej: al cliente + al agente + al sistema),
  deberíamos:
  1. Dividir en sub-steps separados, o
  2. Usar un servicio de batch con idempotency key única para todo el lote

  Ver ADR-004 para justificación de esta decisión arquitectónica.
  """

  @behaviour Beamflow.Workflows.Step
  use Beamflow.Engine.Retry, policy: :email

  require Logger

  @impl true
  def validate(%{applicant_email: email, final_decision: %{status: status}})
      when is_binary(email) and status in [:approved, :rejected] do
    if String.contains?(email, "@") do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  def validate(%{applicant_email: _email}) do
    {:error, :missing_final_decision}
  end

  def validate(_), do: {:error, :missing_applicant_email}

  @impl true
  def execute(state) do
    # La idempotency_key ya viene inyectada por WorkflowActor automáticamente
    idempotency_key = Map.get(state, :idempotency_key, "unknown")

    %{
      applicant_email: email,
      applicant_name: name,
      final_decision: %{status: decision_status} = decision
    } = state

    # Determinar tipo de email según decisión
    email_type = if decision_status == :approved, do: :approval, else: :rejection

    Logger.info("SendConfirmationEmail: Enviando email de #{email_type} a #{email}")

    # Construir contenido según el resultado
    email_content = build_email_content(email_type, name, state, decision)

    # Ejecutar el side-effect pasando la key al servicio externo
    case send_email_to_service(email, email_content, idempotency_key) do
      {:ok, result} ->
        Logger.info("SendConfirmationEmail: Email de #{email_type} enviado exitosamente")

        {:ok, Map.put(state, :confirmation_email_sent, %{
          email: email,
          type: email_type,
          sent_at: result.sent_at,
          message_id: result.message_id,
          idempotency_key: idempotency_key
        })}

      {:error, reason} ->
        {:error, {:email_failed, reason}}
    end
  end

  # ============================================================================
  # Construcción de Contenido del Email
  # ============================================================================

  defp build_email_content(:approval, name, state, _decision) do
    policy_number = Map.get(state, :policy_number, "N/A")
    premium = Map.get(state, :premium_amount, 0)
    vehicle = Map.get(state, :vehicle_model, "N/A")

    %{
      subject: "🎉 ¡Felicidades #{name}! Tu seguro ha sido aprobado",
      body: """
      Hola #{name},

      ¡Excelentes noticias! Tu solicitud de seguro vehicular ha sido APROBADA.

      📋 Detalles de tu póliza:
      ─────────────────────────
      Número de Póliza: #{policy_number}
      Vehículo: #{vehicle}
      Prima Mensual: $#{premium}

      Próximos pasos:
      1. Recibirás tu póliza digital en las próximas 24 horas
      2. El cargo a tu método de pago se realizará automáticamente
      3. Tu cobertura estará activa desde mañana

      ¡Gracias por confiar en BEAMFlow Seguros!

      Saludos,
      El equipo de BEAMFlow
      """,
      template: :approval
    }
  end

  defp build_email_content(:rejection, name, _state, decision) do
    reason = Map.get(decision, :reason, "No especificada")

    %{
      subject: "Resultado de tu solicitud de seguro - #{name}",
      body: """
      Hola #{name},

      Gracias por tu interés en BEAMFlow Seguros.

      Lamentamos informarte que después de evaluar tu solicitud,
      no podemos aprobarla en este momento.

      📋 Razón:
      ─────────────────────────
      #{reason}

      ¿Qué puedes hacer?
      1. Revisar la información proporcionada
      2. Intentar nuevamente en 30 días
      3. Contactar a nuestro equipo para más opciones

      Agradecemos tu comprensión.

      Saludos,
      El equipo de BEAMFlow
      """,
      template: :rejection
    }
  end

  # ============================================================================
  # Envío de Email (Simulación)
  # ============================================================================

  defp send_email_to_service(email, content, idempotency_key) do
    # =========================================================================
    # EN PRODUCCIÓN usaríamos SendGrid, Mailgun, etc.:
    # =========================================================================
    # Req.post("https://api.sendgrid.com/v3/mail/send",
    #   headers: [
    #     {"Authorization", "Bearer #{api_key}"},
    #     {"Idempotency-Key", idempotency_key}
    #   ],
    #   json: %{
    #     personalizations: [%{to: [%{email: email}]}],
    #     from: %{email: "noreply@beamflow.com"},
    #     subject: content.subject,
    #     content: [%{type: "text/plain", value: content.body}]
    #   }
    # )
    # =========================================================================

    # Simulación para desarrollo
    Logger.debug("""
    📧 [SIMULATED EMAIL - #{String.upcase(to_string(content.template))}]
    ═══════════════════════════════════════════════════════════════
    To: #{email}
    Subject: #{content.subject}
    Idempotency-Key: #{idempotency_key}
    ───────────────────────────────────────────────────────────────
    #{content.body}
    ═══════════════════════════════════════════════════════════════
    """)

    # Simular latencia de red
    Process.sleep(Enum.random(50..150))

    {:ok, %{
      sent_at: DateTime.utc_now(),
      message_id: "msg-#{UUID.uuid4()}",
      recipient: email,
      template: content.template
    }}
  end
end
