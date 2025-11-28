# ADR-007: Circuit Breaker y Saga Pattern para Resiliencia

## Estado
**Aceptado** - Noviembre 2024

## Contexto

BEAMFlow ejecuta workflows que interactúan con servicios externos (APIs, bases de datos, servicios de email). Estos servicios pueden:

1. **Fallar temporalmente**: Timeouts, 503s, conexiones rechazadas
2. **Fallar persistentemente**: Servicio caído por mantenimiento
3. **Dejar estado inconsistente**: Un step modifica datos externos y luego otro falla

### Problemas Identificados

```
Escenario 1: Servicio de Email Caído
─────────────────────────────────────
Step 1: Debitar cuenta       ✅ ($500 debitados)
Step 2: Reservar producto    ✅ (Stock reservado)
Step 3: Enviar email         ❌ (SMTP timeout)
        └── Retry 1          ❌ (SMTP timeout)
        └── Retry 2          ❌ (SMTP timeout)
        └── Retry 3          ❌ (SMTP timeout)
        └── Retry 4          ❌ (SMTP timeout)
        └── Retry 5          ❌ (SMTP timeout)

Resultado: Cliente perdió $500, producto reservado, sin confirmación
```

```
Escenario 2: Thundering Herd
────────────────────────────
100 workflows intentan enviar emails simultáneamente
Servicio de email responde lento
100 × 5 reintentos = 500 conexiones
Servicio de email colapsa
Todos los workflows fallan
```

## Decisión

Implementamos dos patrones complementarios:

### 1. Circuit Breaker (Fail Fast)

Protege servicios externos de sobrecarga y evita reintentos innecesarios.

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Circuit Breaker States                         │
│                                                                     │
│    ┌──────────┐   N failures    ┌──────────┐   timeout   ┌────────┐│
│    │  CLOSED  │───────────────►│   OPEN   │────────────►│  HALF  ││
│    │ (normal) │                │ (reject) │             │  OPEN  ││
│    └──────────┘                └──────────┘             └────────┘│
│         ▲                            ▲                      │     │
│         │ success                    │ failure              │     │
│         └────────────────────────────┴──────────────────────┘     │
└─────────────────────────────────────────────────────────────────────┘
```

**Implementación**: `Beamflow.Engine.CircuitBreaker`

```elixir
# Configuración por servicio
{:ok, _} = CircuitBreaker.start_link(
  name: :email_service,
  failure_threshold: 3,      # Abrir después de 3 fallos
  success_threshold: 2,      # Cerrar después de 2 éxitos en half-open
  timeout: :timer.seconds(60) # Tiempo en estado open
)

# Uso en steps
case CircuitBreaker.call(:email_service, fn -> send_email(to, body) end) do
  {:ok, result} -> {:ok, result}
  {:error, :circuit_open} -> {:error, :service_unavailable}
  {:error, reason} -> {:error, reason}
end
```

**Políticas predefinidas**:
- `:email_service` - 3 failures, 60s timeout
- `:payment_gateway` - 2 failures, 120s timeout (más conservador)
- `:external_api` - 5 failures, 30s timeout (más tolerante)
- `:database` - 3 failures, 10s timeout (recuperación rápida)

### 2. Saga Pattern (Compensación)

Garantiza consistencia eventual cuando un step falla después de otros exitosos.

```elixir
defmodule DebitAccountStep do
  use Beamflow.Engine.Saga

  @impl true
  def execute(context, opts) do
    amount = opts[:amount]
    {:ok, tx_id} = BankAPI.debit(context.account_id, amount)
    {:ok, Map.put(context, :transaction_id, tx_id)}
  end

  @impl true
  def compensate(context, opts) do
    # Revertir: acreditar la cuenta
    amount = opts[:amount]
    BankAPI.credit(context.account_id, amount, ref: context.transaction_id)
    {:ok, :credited_back}
  end
end
```

**Flujo de compensación**:

```
Ejecución Normal (izquierda a derecha):
Step1 ─► Step2 ─► Step3 ─► Step4
  ✅       ✅       ✅       ❌

Compensación (derecha a izquierda):
Step3.compensate() ◄─ Step2.compensate() ◄─ Step1.compensate()
        ↩️                   ↩️                    ↩️
```

### 3. Integración con Retry

El sistema de retry consulta el Circuit Breaker antes de intentar:

```elixir
defp execute_with_retry(step_module, state, workflow_id, policy, opts) do
  circuit_breaker = opts[:circuit_breaker]
  
  # Verificar Circuit Breaker antes de intentar
  if circuit_breaker && not CircuitBreaker.allow?(circuit_breaker) do
    {:error, :circuit_open, %{attempt: 0}}
  else
    # Intentar ejecución
    result = step_module.execute(state)
    
    # Reportar al Circuit Breaker
    case result do
      {:ok, _} -> CircuitBreaker.report_success(circuit_breaker)
      {:error, _} -> CircuitBreaker.report_failure(circuit_breaker)
    end
    
    result
  end
end
```

### 4. Integración en WorkflowActor

El actor ejecuta compensaciones automáticamente:

```elixir
defp handle_step_error(step_module, reason, workflow_module, state) do
  %{executed_saga_steps: saga_steps, workflow_state: workflow_state} = state

  # Ejecutar compensaciones en orden LIFO
  if Enum.any?(saga_steps) do
    Logger.warning("Executing #{length(saga_steps)} compensation(s)...")
    
    Saga.compensate(saga_steps, workflow_state,
      on_compensate: fn module, result ->
        record_event(workflow_id, :saga_step_compensated, %{
          step: inspect(module),
          result: inspect(result)
        })
      end
    )
  end
  
  # Continuar con manejo de error normal...
end
```

## Consecuencias

### Positivas

1. **Protección de servicios externos**: Circuit Breaker evita sobrecargar servicios ya estresados
2. **Fail fast**: Workflows fallan rápidamente cuando un servicio está caído
3. **Consistencia eventual**: Saga Pattern garantiza que no queden estados parciales
4. **Observabilidad**: Eventos de compensación y transiciones de circuit breaker son auditables
5. **Configuración granular**: Diferentes políticas para diferentes servicios

### Negativas

1. **Complejidad**: Cada step con side-effects debe implementar `compensate/2`
2. **Compensaciones imperfectas**: No todos los side-effects son 100% reversibles
3. **Latencia adicional**: Circuit Breaker añade overhead (mínimo)
4. **Estado adicional**: Tracking de saga steps en memoria del actor

### Mitigaciones

- **Compensaciones idempotentes**: Usar `idempotency_key` en compensaciones
- **Compensaciones best-effort**: Si una compensación falla, continuar con las demás
- **Logging extensivo**: Registrar todas las compensaciones para auditoría
- **Alertas**: Notificar cuando un Circuit Breaker se abre

## Alternativas Consideradas

### 1. Two-Phase Commit (2PC)
- **Rechazado**: Requiere coordinación síncrona entre servicios
- Latencia alta, bajo throughput, punto único de falla

### 2. Sin compensación (fail-and-log)
- **Rechazado**: Requiere intervención manual para limpiar estados parciales
- No escala con volumen de workflows

### 3. Transacciones distribuidas (Saga orquestado externamente)
- **Rechazado**: Añade dependencia de coordinador externo
- Complica la arquitectura y reduce la resiliencia

## Ejemplos de Uso

### Step con Saga y Circuit Breaker

```elixir
defmodule ProcessPayment do
  use Beamflow.Workflows.Step
  use Beamflow.Engine.Saga
  use Beamflow.Engine.Retry, policy: :payment

  @impl Saga
  def execute(context, _opts) do
    CircuitBreaker.call(:payment_gateway, fn ->
      PaymentGateway.charge(context.card_id, context.amount)
    end)
    |> case do
      {:ok, tx} -> {:ok, Map.put(context, :payment_tx, tx)}
      error -> error
    end
  end

  @impl Saga
  def compensate(context, _opts) do
    CircuitBreaker.call(:payment_gateway, fn ->
      PaymentGateway.refund(context.payment_tx.id)
    end)
  end
end
```

### Workflow con compensación automática

```elixir
defmodule OrderWorkflow do
  use Beamflow.Workflows.Workflow

  def steps do
    [
      ValidateOrder,       # Sin side-effects (no saga)
      DebitAccount,        # Con Saga - compensate: credit_account
      ReserveInventory,    # Con Saga - compensate: release_inventory
      SendConfirmation     # Con Saga - compensate: send_cancellation
    ]
  end
end

# Si SendConfirmation falla después de retry:
# 1. ReserveInventory.compensate() -> libera inventario
# 2. DebitAccount.compensate() -> acredita cuenta
# 3. Workflow marcado como :failed
```

## Métricas y Alertas

### Circuit Breaker
- `circuit_breaker.state_change` - Transiciones de estado
- `circuit_breaker.calls.success` - Llamadas exitosas
- `circuit_breaker.calls.rejected` - Llamadas rechazadas (circuito abierto)
- **Alerta**: Circuit abierto por más de 5 minutos

### Saga
- `saga.compensations.executed` - Compensaciones ejecutadas
- `saga.compensations.failed` - Compensaciones fallidas
- `saga.rollback.duration` - Tiempo de rollback
- **Alerta**: Compensación fallida en workflow de producción

## Referencias

- [Circuit Breaker - Martin Fowler](https://martinfowler.com/bliki/CircuitBreaker.html)
- [Saga Pattern - Microsoft](https://docs.microsoft.com/en-us/azure/architecture/reference-architectures/saga/saga)
- [Release It! - Michael Nygard](https://pragprog.com/titles/mnee2/release-it-second-edition/)
- ADR-004: Sistema de Idempotencia
- ADR-005: Sistema de Retry con Backoff
