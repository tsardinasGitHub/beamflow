# ADR-008: Chaos Engineering para Validación de Resiliencia

## Estado
**Aceptado** - Noviembre 2025

## Contexto

Con la implementación de Circuit Breaker, Saga Pattern, y Dead Letter Queue (ADR-007), necesitamos una forma sistemática de validar que estos mecanismos de resiliencia funcionan correctamente bajo condiciones de fallo. El testing tradicional no es suficiente para verificar comportamiento en producción real.

### Problemas a Resolver

1. **Verificación de recuperación**: ¿Se recuperan los workflows después de crashes?
2. **Validación de idempotencia**: ¿Las operaciones son verdaderamente idempotentes?
3. **Pruebas de compensación**: ¿Las compensaciones Saga funcionan bajo presión?
4. **Comportamiento del Circuit Breaker**: ¿Se activan correctamente los circuit breakers?

## Decisión

Implementamos un sistema de **Chaos Engineering** inspirado en Netflix Chaos Monkey:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Chaos Engineering System                         │
│                                                                         │
│  ┌───────────────────┐    ┌─────────────────────┐    ┌───────────────┐ │
│  │   ChaosMonkey     │───►│   FaultInjector     │───►│  Workflows    │ │
│  │                   │    │                     │    │  & Steps      │ │
│  │  Profiles:        │    │  Fault Types:       │    │               │ │
│  │  • gentle         │    │  • :crash           │    │  Results:     │ │
│  │  • moderate       │    │  • :timeout         │    │  • Recovery   │ │
│  │  • aggressive     │    │  • :error           │    │  • Metrics    │ │
│  │                   │    │  • :latency         │    │  • Alerts     │ │
│  │  Controls:        │    │  • :compensation_   │    │               │ │
│  │  • start/stop     │    │     fail            │    │               │ │
│  │  • inject         │    │                     │    │               │ │
│  └───────────────────┘    └─────────────────────┘    └───────────────┘ │
│           │                                                    ▲        │
│           │              ┌─────────────────────┐               │        │
│           └─────────────►│ IdempotencyValidator│───────────────┘        │
│                          │                     │                        │
│                          │ Validates:          │                        │
│                          │ • Step idempotency  │                        │
│                          │ • Compensation idem │                        │
│                          │ • Recovery idem     │                        │
│                          └─────────────────────┘                        │
└─────────────────────────────────────────────────────────────────────────┘
```

### Componentes Implementados

#### 1. ChaosMonkey (`lib/beamflow/chaos/chaos_monkey.ex`)

GenServer central que controla la inyección de fallos:

```elixir
# Iniciar chaos mode
ChaosMonkey.start(:gentle)

# Inyectar fallo específico
ChaosMonkey.inject(:crash, target: :random_workflow)

# Cambiar perfil
ChaosMonkey.set_profile(:aggressive)

# Ver estadísticas
ChaosMonkey.stats()
```

**Perfiles disponibles:**

| Perfil      | Crash % | Timeout % | Error % | Latency % | Interval |
|-------------|---------|-----------|---------|-----------|----------|
| gentle      | 5%      | 3%        | 8%      | 10%       | 10s      |
| moderate    | 15%     | 10%       | 20%     | 25%       | 5s       |
| aggressive  | 30%     | 20%       | 35%     | 40%       | 2s       |

#### 2. FaultInjector (`lib/beamflow/chaos/fault_injector.ex`)

Funciones para opt-in a chaos testing dentro de steps:

```elixir
defmodule MyStep do
  import Beamflow.Chaos.FaultInjector

  def execute(state) do
    # Posible crash aleatorio (solo si chaos mode activo)
    maybe_crash!(:step_execution)

    # Posible latencia
    maybe_delay(:network_call, 100..500)

    # Operación real
    do_something(state)
  end
end
```

**Funciones disponibles:**

- `maybe_crash!/1` - Lanza excepción aleatoriamente
- `maybe_delay/2` - Introduce latencia aleatoria
- `maybe_error/1` - Retorna error aleatorio
- `maybe_timeout/2` - Simula timeout
- `maybe_fail_compensation/1` - Falla compensaciones Saga

#### 3. IdempotencyValidator (`lib/beamflow/chaos/idempotency_validator.ex`)

Valida que steps son verdaderamente idempotentes:

```elixir
# Validar un step
{:ok, :idempotent} = IdempotencyValidator.validate(ProcessPayment, %{
  amount: 100,
  card_id: "card_123",
  idempotency_key: "unique-key"
})

# Ver reporte
IdempotencyValidator.report()
# => %{idempotency_rate: 95.5, total_validations: 100, ...}
```

#### 4. ChaosAwareStep (Ejemplo)

Step de demostración que integra todas las capacidades:

```elixir
defmodule ChaosAwareStep do
  @behaviour Beamflow.Workflows.Step
  use Beamflow.Engine.Saga
  use Beamflow.Engine.Retry, policy: :conservative

  import Beamflow.Chaos.FaultInjector

  def execute(state) do
    # Verificar idempotencia
    case check_already_executed(idempotency_key) do
      {:ok, cached} -> {:ok, cached}
      :not_found -> execute_with_chaos(state)
    end
  end

  defp execute_with_chaos(state) do
    maybe_crash!(:chaos_aware_step)
    maybe_delay(:processing)
    # ... operación real ...
  end

  def compensate(context, _opts) do
    maybe_fail_compensation(:chaos_aware_step)
    # ... compensación real ...
  end
end
```

## Seguridad

### ⚠️ Protecciones Implementadas

1. **Verificación de entorno**: ChaosMonkey rechaza ejecutarse en producción
2. **Deshabilitado por defecto**: No afecta código existente
3. **Opt-in explícito**: Steps deben importar FaultInjector explícitamente
4. **Control granular**: Perfiles permiten controlar intensidad

```elixir
# application.ex - ChaosMonkey inicia pero NO está activo
Beamflow.Chaos.ChaosMonkey

# Solo se activa explícitamente
ChaosMonkey.start(:gentle)  # ❌ Falla en :prod
```

## Métricas y Observabilidad

El sistema proporciona métricas detalladas:

```elixir
ChaosMonkey.stats()
# => %{
#   enabled: true,
#   profile: :moderate,
#   uptime_seconds: 3600,
#   total_injections: 150,
#   crashes: 25,
#   timeouts: 30,
#   errors: 45,
#   latencies: 50,
#   successful_recoveries: 140,
#   failed_recoveries: 10
# }
```

## Integración con AlertSystem

Los eventos de chaos se integran con el sistema de alertas:

```elixir
# Cuando ChaosMonkey se activa
AlertSystem.send_alert(%{
  severity: :high,
  type: :chaos_mode,
  title: "Chaos Mode Activated",
  message: "ChaosMonkey started with profile: aggressive"
})
```

## Casos de Uso

### 1. Validar Resiliencia en Desarrollo

```bash
# Terminal 1: Iniciar aplicación
mix phx.server

# Terminal 2: Activar chaos
iex> ChaosMonkey.start(:moderate)

# Observar comportamiento en dashboard
# http://localhost:4000/dashboard
```

### 2. Test de Carga con Fallos

```elixir
# En test
test "system recovers from random failures" do
  ChaosMonkey.start(:aggressive)
  
  # Lanzar 100 workflows
  for i <- 1..100 do
    WorkflowRunner.start(SomeWorkflow, %{id: i})
  end
  
  # Esperar procesamiento
  Process.sleep(30_000)
  
  stats = ChaosMonkey.stats()
  assert stats.successful_recoveries > stats.failed_recoveries
end
```

### 3. Validación de Idempotencia

```elixir
test "ProcessPayment is idempotent" do
  {:ok, :idempotent} = IdempotencyValidator.validate(
    ProcessPayment,
    %{amount: 100, card_id: "card_123"},
    executions: 5
  )
end
```

## Alternativas Consideradas

1. **Chaos Mesh (Kubernetes)**: Demasiado complejo para desarrollo local
2. **Failure injection en infraestructura**: No permite control granular de código
3. **Tests con mocks de fallos**: No representa escenarios reales

## Consecuencias

### Positivas

- ✅ Validación proactiva de resiliencia
- ✅ Detección temprana de problemas de idempotencia
- ✅ Métricas de recuperación cuantificables
- ✅ Documentación viva del comportamiento bajo fallos

### Negativas

- ⚠️ Complejidad adicional en codebase
- ⚠️ Posible confusión si se activa accidentalmente
- ⚠️ Overhead de runtime (mínimo cuando deshabilitado)

## Referencias

- [Netflix Chaos Monkey](https://netflix.github.io/chaosmonkey/)
- [Principles of Chaos Engineering](https://principlesofchaos.org/)
- [ADR-007: Circuit Breaker y Saga Pattern](./007-circuit-breaker-saga-pattern.md)
