# ADR-004: Patrón de Idempotencia para Steps con Side-Effects

- **Fecha:** 2025-11-28
- **Estado:** Aceptado
- **Autores:** Taelen Sardiñas

---

## Contexto

Los workflows de Beamflow ejecutan steps que pueden tener efectos secundarios:
- Enviar emails de confirmación
- Procesar pagos
- Llamar APIs externas
- Actualizar sistemas legacy

### El Problema de Exactly-Once

Cuando un nodo crashea **después** de ejecutar un side-effect pero **antes** de
persistir el resultado, el sistema enfrenta un dilema:

```
Timeline de Crash:
──────────────────────────────────────────────────────────────────
execute()           persist_state()        record_event()
    │                      │                     │
    ▼                      ▼                     ▼
[EMAIL SENT] ────► [CRASH AQUÍ] ────────► [Nunca ejecutado]
──────────────────────────────────────────────────────────────────

Al reiniciar:
1. Mnesia indica: step_index = N (el step N no se completó)
2. El supervisor reinicia el actor
3. El actor re-ejecuta step N
4. ¡El email se envía DOS VECES!
```

### Opciones de Semántica de Entrega

| Semántica | Descripción | Problema |
|-----------|-------------|----------|
| **At-most-once** | Ejecutar máximo una vez | Puede perder operaciones |
| **At-least-once** | Ejecutar mínimo una vez | Puede duplicar operaciones |
| **Exactly-once** | Ejecutar exactamente una vez | Requiere idempotencia |

---

## Decisión

Implementar **Exactly-Once** mediante el **Outbox Pattern + Idempotency Keys**
con **enfoque centralizado en WorkflowActor**.

### Centralizado vs Descentralizado

Evaluamos dos enfoques antes de decidir:

| Aspecto | Centralizado (WorkflowActor) | Descentralizado (Step) |
|---------|------------------------------|------------------------|
| **DRY** | ✅ Una sola implementación | ❌ Duplicación en cada step |
| **Consistencia** | ✅ Garantizada automáticamente | ⚠️ Depende del desarrollador |
| **Flexibilidad** | ⚠️ Menos control por step | ✅ Total control |
| **Errores humanos** | ✅ Imposible olvidarse | ❌ Fácil olvidar |
| **Transparencia** | ✅ Steps simples y limpios | ❌ Lógica mezclada |
| **Testing** | ✅ Steps como funciones puras | ❌ Requiere mocking |

**Elegimos CENTRALIZADO** porque:

1. **Separation of Concerns** - El step hace lógica de negocio, el actor maneja durabilidad
2. **Principio de Mínima Sorpresa** - Los steps no deberían preocuparse por infraestructura
3. **Patrón de Frameworks Maduros** - Así funcionan Temporal.io, AWS Step Functions, Cadence

### Arquitectura Centralizada

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         WORKFLOW ACTOR                                      │
│                                                                             │
│  execute_step/3                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                                                                     │   │
│  │  FASE 1: BEFORE_EXECUTE                                             │   │
│  │  ─────────────────────                                              │   │
│  │  case Idempotency.begin_step(workflow_id, step_module) do           │   │
│  │    {:already_completed, cached} -> usar resultado cacheado          │   │
│  │    {:already_pending, key}      -> retry con misma key              │   │
│  │    {:ok, key}                   -> nueva ejecución                  │   │
│  │  end                                                                │   │
│  │                                                                     │   │
│  │  FASE 2: EXECUTE                                                    │   │
│  │  ──────────────────                                                 │   │
│  │  enriched_state = Map.put(state, :idempotency_key, key)             │   │
│  │  step_module.execute(enriched_state)  ◄── Key inyectada             │   │
│  │                                                                     │   │
│  │  FASE 3: AFTER_EXECUTE                                              │   │
│  │  ─────────────────────                                              │   │
│  │  Idempotency.complete_step(key, result)                             │   │
│  │  # o Idempotency.fail_step(key, error)                              │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         STEP (Lógica Pura)                                  │
│                                                                             │
│  def execute(%{idempotency_key: key} = state) do                            │
│    # Solo lógica de negocio                                                 │
│    EmailService.send(to: state.email, idempotency_key: key)                 │
│    #                                   ▲                                    │
│    #                                   │                                    │
│    #                    Key viene inyectada por WorkflowActor               │
│  end                                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Flujo de Recuperación ante Crash

```elixir
# Al reiniciar el workflow
case Idempotency.check_step_status(workflow_id, step_module) do
  :not_started ->
    # Caso normal: ejecutar step
    execute_with_idempotency(step_module, state)

  {:pending, key, started_at} ->
    # Crash durante ejecución
    Logger.warning("Recovering from crash: #{key}")

    # El servicio externo ya tiene la key, no re-ejecutará
    # Solo volvemos a llamar con la misma key
    retry_with_same_key(step_module, key, state)

  {:completed, cached_result} ->
    # Step ya completado, usar resultado cacheado
    {:ok, cached_result}

  {:failed, error} ->
    # Falló antes, decidir si reintentar
    {:error, error}
end
```

### Componentes Implementados

1. **`Beamflow.Engine.Idempotency`** - API de alto nivel
   - `begin_step/3` - Registrar intención antes de ejecutar
   - `complete_step/2` - Marcar como completado
   - `fail_step/2` - Marcar como fallido
   - `check_step_status/2` - Verificar estado para recuperación

2. **`Beamflow.Storage.IdempotencyStore`** - Persistencia Mnesia
   - Tabla `:beamflow_idempotency` con índice en status
   - Transacciones ACID para consistencia

3. **Tabla Mnesia: `:beamflow_idempotency`**
   ```
   | Campo        | Tipo     | Descripción                          |
   |--------------|----------|--------------------------------------|
   | key          | String   | "{workflow}:{step}:{attempt}"        |
   | status       | atom     | :pending | :completed | :failed     |
   | started_at   | DateTime | Timestamp de inicio                  |
   | completed_at | DateTime | Timestamp de fin (nil si pending)    |
   | result       | map      | Resultado cacheado del step          |
   | error        | term     | Error si falló                       |
   ```

---

## Consecuencias

### Positivas

1. **Garantía de exactly-once** para side-effects externos
2. **Recuperación automática** ante crashes sin intervención manual
3. **Auditoría completa** de intentos y resultados
4. **Compatible con servicios modernos** (Stripe, SendGrid, etc.)
5. **Transparente para steps sin side-effects** (no requiere cambios)

### Negativas

1. **Overhead de almacenamiento** - Una entrada por step ejecutado
2. **Latencia adicional** - Dos escrituras Mnesia por step
3. **Requisito en servicios externos** - Deben soportar idempotency keys
4. **Limpieza periódica necesaria** - Registros antiguos deben purgarse

### Mitigaciones

| Negativa | Mitigación |
|----------|------------|
| Overhead almacenamiento | `Idempotency.cleanup/1` elimina registros >24h |
| Latencia adicional | ram_copies en desarrollo, async writes |
| Servicios externos | Wrapper con fallback a deduplicación local |
| Limpieza | Job periódico o limpieza al completar workflow |

---

## Alternativas Consideradas

### 1. Two-Phase Commit (2PC)

**Pros:** Garantía distribuida estricta
**Contras:** Complejidad extrema, latencia alta, bloqueos
**Descartada:** Overkill para el caso de uso

### 2. Saga Pattern con Compensación

**Pros:** Estándar en microservicios
**Contras:** Requiere implementar "undo" para cada step
**Descartada:** No todos los side-effects son reversibles (¿des-enviar email?)

### 3. Event Sourcing Completo

**Pros:** Reconstrucción perfecta del estado
**Contras:** Complejidad arquitectónica significativa
**Descartada:** Excede necesidades del proyecto actual

### 4. Idempotency Keys (Elegida)

**Pros:** Simple, compatible con servicios existentes, bajo overhead
**Contras:** Requiere cooperación de servicios externos
**Elegida:** Balance óptimo entre simplicidad y garantías

---

## Implementación de Steps (Simplificada)

### Step SIN side-effects (no requiere cambios)

```elixir
defmodule ValidateData do
  @behaviour Beamflow.Workflows.Step

  def execute(state) do
    # Solo validación en memoria - naturalmente idempotente
    # No necesita usar idempotency_key
    if valid?(state.data) do
      {:ok, Map.put(state, :validated, true)}
    else
      {:error, :invalid_data}
    end
  end
end
```

### Step CON side-effects (usa key inyectada)

```elixir
defmodule SendEmail do
  @behaviour Beamflow.Workflows.Step

  def execute(state) do
    # La key viene INYECTADA por WorkflowActor automáticamente
    # El step NO necesita preocuparse por idempotencia
    idempotency_key = Map.get(state, :idempotency_key)

    # Solo pasar la key al servicio externo
    case EmailService.send(
      to: state.email,
      idempotency_key: idempotency_key  # ← El servicio deduplica
    ) do
      {:ok, _} -> {:ok, Map.put(state, :email_sent, true)}
      {:error, e} -> {:error, e}
    end
  end
end
```

### Comparación: Antes vs Después

**ANTES (Descentralizado - 40 líneas por step)**:
```elixir
def execute(state) do
  key = generate_idempotency_key(state)

  case IdempotencyStore.get_status(key) do
    {:completed, result} -> {:ok, result}
    :not_found ->
      IdempotencyStore.mark_pending(key)

      case do_side_effect() do
        {:ok, result} ->
          IdempotencyStore.mark_completed(key, result)
          {:ok, result}
        error ->
          IdempotencyStore.mark_failed(key, error)
          error
      end
  end
end
```

**DESPUÉS (Centralizado - 10 líneas por step)**:
```elixir
def execute(%{idempotency_key: key} = state) do
  case EmailService.send(to: state.email, key: key) do
    {:ok, _} -> {:ok, Map.put(state, :email_sent, true)}
    {:error, e} -> {:error, e}
  end
end
```

**Reducción: ~75% menos código por step**

---

## Principio de Atomicidad de Steps

### Regla de Oro

> **"Un step = una operación atómica con un solo side-effect externo"**

### ¿Por qué NO checkpoints internos?

Si un step necesita realizar múltiples operaciones (ej: enviar 3 emails), tenemos dos opciones:

| Enfoque | Implementación | Recomendación |
|---------|----------------|---------------|
| **Dividir en sub-steps** | 3 steps separados: `SendEmail1`, `SendEmail2`, `SendEmail3` | ✅ Preferido |
| **Batch con key única** | Un servicio que maneje el lote completo idempotentemente | ✅ Alternativa |
| **Checkpoints internos** | Lógica compleja dentro del step para trackear progreso | ❌ Evitar |

### Ejemplo: Envío Múltiple

**❌ MAL - Step con checkpoints internos:**
```elixir
def execute(state) do
  # Complejidad explosiva, testing difícil
  emails = [:client, :agent, :system]
  
  Enum.reduce_while(emails, {:ok, state}, fn type, {:ok, acc} ->
    if already_sent?(state, type) do
      {:cont, {:ok, acc}}
    else
      case send_and_checkpoint(type, acc) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        error -> {:halt, error}
      end
    end
  end)
end
```

**✅ BIEN - Dividir en steps atómicos:**
```elixir
# Workflow define 3 steps separados
def steps do
  [
    ...,
    ApproveRequest,
    SendClientEmail,      # Step atómico
    SendAgentEmail,       # Step atómico  
    SendSystemEmail       # Step atómico
  ]
end
```

**✅ BIEN - Batch con idempotency key:**
```elixir
def execute(%{idempotency_key: key} = state) do
  # El servicio maneja el batch completo de forma idempotente
  EmailService.send_batch(
    recipients: [state.client, state.agent, state.system],
    idempotency_key: key  # Una key para todo el lote
  )
end
```

---

## Monitoreo y Alertas

### Métricas a Observar

1. **Registros :pending antiguos** (>5 min) → Posible crash no recuperado
2. **Ratio de :already_sent** → Indica frecuencia de recuperaciones
3. **Tamaño de tabla** → Verificar que cleanup funciona

### Queries de Diagnóstico

```elixir
# Ver steps pendientes (posibles crashes)
IdempotencyStore.list_pending()

# Estadísticas
IdempotencyStore.stats()
# => %{pending: 0, completed: 1523, failed: 12}

# Limpiar registros >24h
Idempotency.cleanup(DateTime.add(DateTime.utc_now(), -24, :hour))
```

---

## Referencias

- [Stripe Idempotency](https://stripe.com/docs/api/idempotent_requests)
- [SendGrid Idempotency](https://docs.sendgrid.com/api-reference/how-to-use-the-sendgrid-v3-api/idempotency)
- [Designing Data-Intensive Applications - Ch. 11](https://dataintensive.net/)
- [Outbox Pattern - microservices.io](https://microservices.io/patterns/data/transactional-outbox.html)
