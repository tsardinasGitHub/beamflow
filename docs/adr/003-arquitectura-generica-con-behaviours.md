# ADR-003: Arquitectura Genérica con Elixir Behaviours

**Fecha**: 2025-01-15  
**Estado**: Aceptado  
**Contexto**: Proyecto de portfolio - BEAMFlow Workflow Orchestrator  
**Relacionado con**: ADR-001 (Uso de Mnesia), ADR-002 (Estándares de Documentación)

---

## Contexto

BEAMFlow comenzó como un motor de workflows genérico, pero se identificó la necesidad de demostrar un **caso de uso concreto y humanizado** para facilitar la comprensión del proyecto a reclutadores técnicos y evaluadores.

El caso de uso elegido es: **Procesamiento de Solicitudes de Seguro Vehicular**, con un pipeline de 4 pasos:

1. Validación de identidad (DNI)
2. Verificación de historial crediticio
3. Evaluación del riesgo del vehículo
4. Aprobación o rechazo automático

### Dilema Arquitectónico

Se presentaron dos opciones:

**A) Motor Genérico + Capa de Dominio Específico**
- Definir behaviours (`Workflow` y `Step`)
- Implementar caso de uso de seguros como un dominio que usa esos behaviours
- Engine (`WorkflowActor`, `WorkflowSupervisor`) permanece agnóstico del dominio

**B) Implementación Específica a Seguros**
- Código directamente acoplado al dominio de seguros
- Sin abstracciones intermedias
- Más rápido de desarrollar inicialmente

---

## Decisión

**Se adopta la Opción A: Arquitectura Genérica con Elixir Behaviours.**

El motor de workflows (`Beamflow.Engine`) será **completamente polimórfico**, permitiendo que cualquier dominio de negocio implemente sus propios workflows mediante la implementación de dos behaviours:

### 1. `Beamflow.Workflows.Workflow` (Behaviour)

Define el contrato para un tipo de workflow:

```elixir
@callback steps() :: [module()]
@callback initial_state(params :: map()) :: map()
@callback handle_step_success(step :: module(), state :: map()) :: map()
@callback handle_step_failure(step :: module(), reason :: term(), state :: map()) :: map()
```

### 2. `Beamflow.Workflows.Step` (Behaviour)

Define el contrato para un paso ejecutable:

```elixir
@callback execute(state :: map()) :: {:ok, map()} | {:error, term()}
@callback validate(state :: map()) :: :ok | {:error, term()}
```

### Arquitectura de Capas

```
┌─────────────────────────────────────────────────────────┐
│         BeamflowWeb (Phoenix LiveView)                  │
│  - Dashboard genérico que lista workflows polimórficos  │
│  - Detalle con timeline de steps                        │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│      Beamflow.Domains.Insurance (Caso de Uso)           │
│  - InsuranceWorkflow (implementa Workflow behaviour)    │
│  - Steps: ValidateIdentity, CheckCredit, etc.           │
│  - Contexto público: create_request/1, start/1          │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│       Beamflow.Engine (Motor Genérico OTP)              │
│  - WorkflowActor (GenServer polimórfico)                │
│  - WorkflowSupervisor (DynamicSupervisor)               │
│  - Registry (proceso lookup)                            │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│       Beamflow.Workflows.Repo (Persistencia)            │
│  - Tabla Mnesia :workflows (polimórfica)                │
│  - Almacena: workflow_module, status, state, history    │
└─────────────────────────────────────────────────────────┘
```

---

## Justificación

### ✅ Por qué Opción A es superior para un proyecto de portfolio

#### 1. **Demuestra Madurez Arquitectónica**
- Separación de concerns (engine vs. dominio)
- Pensamiento en extensibilidad desde día 1
- No es premature optimization: es **diseño intencional**

#### 2. **Facilita Demostraciones en Vivo**
En una entrevista técnica:
> "El motor ejecuta cualquier workflow que implemente el behaviour. Mira, te muestro cómo agregar procesamiento de préstamos en 15 minutos..."

Esto es **mucho más impresionante** que:
> "Es un sistema de seguros. Para otro dominio... tendría que refactorizar todo."

#### 3. **Alineado con Filosofía Elixir**
- Behaviours son idiomáticos en Elixir
- GenServer, Supervisor, Application son behaviours
- Demuestra conocimiento profundo del lenguaje

#### 4. **Testeable por Diseño**
```elixir
# Mock de un Step en tests
defmodule FakeStep do
  @behaviour Beamflow.Workflows.Step
  
  def execute(_state), do: {:ok, %{fake: true}}
  def validate(_state), do: :ok
end
```

Mockear behaviours es estándar. Mockear implementaciones concretas es frágil.

#### 5. **Escalabilidad Real**
Agregar un nuevo dominio (ej: "Procesamiento de Préstamos"):

```elixir
# lib/beamflow/domains/loans/loan_workflow.ex
defmodule Beamflow.Domains.Loans.LoanWorkflow do
  @behaviour Beamflow.Workflows.Workflow
  
  def steps, do: [VerifyIncome, CheckCollateral, ApproveLoan]
  # ... resto de callbacks
end
```

**Sin tocar una línea del Engine, Repo, Dashboard base, o tests.**

---

## Consecuencias

### Positivas

✅ **Extensibilidad sin fricción**: Nuevos dominios = nuevos módulos  
✅ **Reutilización de infraestructura**: Chaos Mode, Telemetry, PubSub funcionan para todos  
✅ **Testing robusto**: Behaviours se mockean fácilmente  
✅ **Valor de portfolio**: Demuestra pensamiento senior vs. tutorial-following  
✅ **Narrativa clara**: "Motor genérico + caso de uso demo"

### Negativas

⚠️ **Mayor tiempo inicial**: +2-3 horas vs. implementación directa  
⚠️ **Más abstracciones**: Curva de aprendizaje para nuevos colaboradores  
⚠️ **Riesgo de over-engineering**: Si solo habrá 1 dominio, es YAGNI

### Mitigaciones

- **Tiempo**: Este es un proyecto de portfolio, no un MVP con deadline
- **Abstracciones**: Documentación exhaustiva y ejemplos claros (ADR-002)
- **Over-engineering**: El objetivo **ES** demostrar arquitectura, no shipping rápido

---

## Implementación

### Orden de Desarrollo

#### Fase 1: Behaviours Base (1-2h)
1. ✅ Crear `lib/beamflow/workflows/workflow.ex` (behaviour + @type)
2. ✅ Crear `lib/beamflow/workflows/step.ex` (behaviour + @type)
3. ✅ Refactorizar `WorkflowActor` para recibir `workflow_module`

#### Fase 2: Dominio Insurance (3-4h)
4. ✅ Crear `InsuranceWorkflow` implementando behaviour
5. ✅ Implementar los 4 steps con lógica realista
6. ✅ Contexto público `Beamflow.Domains.Insurance`

#### Fase 3: Persistencia Polimórfica (1h)
7. ✅ Actualizar Mnesia schema con campo `workflow_module`
8. ✅ Repo genérico que serializa/deserializa workflows polimórficos

#### Fase 4: Dashboard Agnóstico (2h)
9. ✅ LiveView que lista workflows de cualquier tipo
10. ✅ Detalle con timeline de steps dinámico

**Total estimado: 6-9 horas**

---

## Alternativas Consideradas

### Opción B: Implementación Directa (Rechazada)

**Ventajas:**
- ⏱️ MVP en 4 horas
- 📉 Menos código total
- 🎯 Narrativa simple ("es un sistema de seguros")

**Por qué se rechazó:**
- ❌ No escala: agregar otro dominio = duplicar todo
- ❌ Acoplamiento: Engine mezclado con lógica de seguros
- ❌ Difícil de testear: mocks invasivos
- ❌ Portfolio mediocre: parece código de tutorial

### Opción C: Framework Completo tipo Temporal/Oban (Rechazada)

Construir un framework genérico completo con DSL, schedulers, retries configurables, etc.

**Por qué se rechazó:**
- ⚠️ Scope creep masivo (semanas de desarrollo)
- ⚠️ Aleja del objetivo: demostrar OTP, no crear Oban 2.0
- ⚠️ Complejidad innecesaria para el caso de uso

---

## Ejemplos de Código

### Implementación del Workflow de Seguros

```elixir
defmodule Beamflow.Domains.Insurance.InsuranceWorkflow do
  @behaviour Beamflow.Workflows.Workflow
  
  alias Beamflow.Domains.Insurance.Steps.{
    ValidateIdentity,
    CheckCreditScore,
    EvaluateVehicleRisk,
    ApproveRequest
  }
  
  @impl true
  def steps do
    [ValidateIdentity, CheckCreditScore, EvaluateVehicleRisk, ApproveRequest]
  end
  
  @impl true
  def initial_state(params) do
    %{
      applicant_name: params["applicant_name"],
      dni: params["dni"],
      vehicle_model: params["vehicle_model"],
      vehicle_year: params["vehicle_year"],
      vehicle_plate: params["vehicle_plate"],
      status: :pending,
      current_step: 0
    }
  end
  
  @impl true
  def handle_step_success(_step, state) do
    %{state | current_step: state.current_step + 1}
  end
  
  @impl true  
  def handle_step_failure(_step, reason, state) do
    %{state | status: :failed, rejection_reason: inspect(reason)}
  end
end
```

### Ejemplo de Step con Simulación Realista

```elixir
defmodule Beamflow.Domains.Insurance.Steps.ValidateIdentity do
  @behaviour Beamflow.Workflows.Step
  
  @impl true
  def execute(%{dni: dni} = state) do
    # Simular latencia de API externa (RENIEC)
    Process.sleep(Enum.random(100..1200))
    
    # 10% probabilidad de fallo del servicio
    case Enum.random(1..10) do
      1 -> 
        {:error, :service_unavailable}
      _ -> 
        {:ok, Map.put(state, :identity_validated, %{dni: dni, status: :valid})}
    end
  end
  
  @impl true
  def validate(%{dni: dni}) when is_binary(dni) and byte_size(dni) == 8, do: :ok
  def validate(_), do: {:error, :invalid_dni}
end
```

---

## Métricas de Éxito

| Criterio | Objetivo |
|----------|----------|
| **Tiempo de desarrollo** | < 10 horas totales |
| **Líneas de código** | < 1500 LOC (excluyendo tests) |
| **Cobertura de tests** | > 85% |
| **Tiempo agregar nuevo dominio** | < 2 horas |
| **Facilidad de demo** | Mostrar extensibilidad en < 15 min |

---

## Referencias

- [Elixir Behaviours Guide](https://elixir-lang.org/getting-started/typespecs-and-behaviours.html#behaviours)
- [OTP Design Principles](https://www.erlang.org/doc/design_principles/des_princ.html)
- ADR-001: Uso de Mnesia para Persistencia
- ADR-002: Estándares de Documentación y Testing
- [Clean Architecture in Elixir](https://blog.appsignal.com/2020/04/07/elixir-alchemy-clean-architecture-in-elixir.html)

---

## Notas de Implementación

### Compatibilidad con Código Existente

El código base ya tiene:
- ✅ `WorkflowActor` (GenServer) - se refactoriza para polimorfismo
- ✅ `WorkflowSupervisor` (DynamicSupervisor) - permanece igual
- ✅ `Registry` - permanece igual
- ✅ Mnesia setup - se actualiza schema

### Plan de Migración

No hay "migración" porque el proyecto está en fase inicial. Simplemente:

1. Definir behaviours
2. Actualizar `WorkflowActor.init/1` para recibir `{workflow_module, id, params}`
3. Implementar caso de uso de seguros
4. Actualizar dashboard para workflows polimórficos

**Sin breaking changes** porque aún no hay código legacy.

---

## Aprobación

Esta decisión ha sido **aceptada** como la dirección arquitectónica fundamental de BEAMFlow.

El proyecto se posiciona como:
> "Un motor de workflows distribuido y tolerante a fallos construido con OTP, demostrado mediante un caso de uso realista de seguros vehiculares, pero diseñado para escalar a cualquier dominio de negocio."

**Autor**: Desarrollador BEAMFlow  
**Revisores**: N/A (proyecto individual de portfolio)  
**Fecha de implementación**: Enero 2025
