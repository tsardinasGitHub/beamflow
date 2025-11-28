# ADR-005: Soporte para Branching en Workflows

- **Fecha:** 2025-11-28
- **Estado:** Aceptado
- **Autores:** Taelen Sardiñas

---

## Contexto

El motor de workflows de BEAMFlow inicialmente soportaba solo flujos lineales:

```
Step1 → Step2 → Step3 → Step4 → Step5
```

Sin embargo, los workflows del mundo real frecuentemente requieren:
- **Bifurcaciones condicionales**: "Si aprobado, ir a path A; si rechazado, ir a path B"
- **Saltos de steps**: "Si el cliente es VIP, saltar validación manual"
- **Convergencia (joins)**: Múltiples paths que se unen en un punto común

### Ejemplo Real: Workflow de Seguros

```
                                    ┌─ Aprobado → SendApprovalEmail ─┐
ValidateIdentity → CheckCredit → ApproveRequest ─┤                    ├→ CloseCase
                                    └─ Rechazado → SendRejectionEmail┘
```

---

## Decisión

Implementar **Branching Simple con Grafos** manteniendo retrocompatibilidad total.

### Arquitectura de Grafos

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         WORKFLOW GRAPH                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  struct Graph {                                                             │
│    nodes: %{                                                                │
│      "step_0" => %{id, module: ValidateIdentity, type: :step},              │
│      "step_1" => %{id, module: CheckCredit, type: :step},                   │
│      "branch_1" => %{id, type: :branch, condition: &(&1.approved)},         │
│      "step_2a" => %{id, module: SendApproval, type: :step},                 │
│      "step_2b" => %{id, module: SendRejection, type: :step},                │
│      "step_3" => %{id, module: CloseCase, type: :step}                      │
│    },                                                                       │
│    edges: %{                                                                │
│      "step_0" => ["step_1"],                                                │
│      "step_1" => ["branch_1"],                                              │
│      "branch_1" => [{"step_2a", true}, {"step_2b", false}],                 │
│      "step_2a" => ["step_3"],                                               │
│      "step_2b" => ["step_3"]                                                │
│    },                                                                       │
│    start_node: "step_0",                                                    │
│    end_nodes: ["step_3"]                                                    │
│  }                                                                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Tipos de Nodos

| Tipo | Descripción | Ejecución |
|------|-------------|-----------|
| `:step` | Paso ejecutable | Llama a `module.execute(state)` |
| `:branch` | Bifurcación | Evalúa `condition.(state)` y sigue path |
| `:join` | Convergencia | Punto de unión, simplemente continúa |
| `:start` | Inicio | Marca de inicio del grafo |
| `:end` | Final | Marca de fin del workflow |

### Retrocompatibilidad

Los workflows existentes que definen `steps/0` como lista siguen funcionando:

```elixir
# ANTES (sigue funcionando)
def steps do
  [Step1, Step2, Step3]
end

# El Builder detecta esto y crea un grafo lineal automáticamente
```

### Nuevo: DSL para Branching

```elixir
defmodule MyWorkflow do
  use Beamflow.Workflows.DSL

  workflow do
    step ValidateIdentity
    step CheckCredit

    branch :approval_decision, &(&1.approved) do
      true  -> step SendApprovalEmail
      false -> step SendRejectionEmail
    end

    step CloseCase  # Join implícito
  end
end
```

---

## Componentes Implementados

### 1. `Beamflow.Workflows.Graph`

Estructura de datos para representar workflows como grafos dirigidos.

```elixir
# API Principal
Graph.new()                           # Grafo vacío
Graph.from_linear_steps([...])        # Lista → Grafo lineal
Graph.add_step(graph, id, module)     # Agregar paso
Graph.add_branch(graph, id, condition) # Agregar bifurcación
Graph.connect(graph, from, to)        # Conectar nodos
Graph.next_nodes(graph, id, state)    # Obtener siguiente(s)
Graph.is_end_node?(graph, id)         # ¿Es terminal?
```

### 2. `Beamflow.Workflows.Builder`

Construye grafos desde definiciones de workflow.

```elixir
# Detecta tipo de workflow y construye grafo apropiado
graph = Builder.build(MyWorkflow)

# Utilidades
Builder.has_branching?(MyWorkflow)    # ¿Tiene branching?
Builder.get_next_step(graph, id, state) # Siguiente paso
```

### 3. `Beamflow.Workflows.DSL` (Futuro)

DSL declarativo para definir workflows con branching.

```elixir
use Beamflow.Workflows.DSL

workflow do
  step Step1
  step Step2

  branch :decision, &(&1.value > 100) do
    true  -> step HighValuePath
    false -> step LowValuePath
  end
end
```

### 4. `Beamflow.Engine.WorkflowActor` (Actualizado)

El actor ahora ejecuta grafos en lugar de listas lineales.

```elixir
# Cambios principales:
- graph: Graph.t()           # Nuevo: grafo del workflow
- current_node_id: String.t() # Nuevo: nodo actual (vs índice)
- executed_nodes: [String.t()] # Nuevo: historial de nodos

# Manejo de nodos:
- :step → ejecutar módulo
- :branch → evaluar condición y seguir path
- :join → continuar al siguiente
```

---

## Flujo de Ejecución con Branching

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WORKFLOW ACTOR - EJECUCIÓN DE GRAFO                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  handle_continue(:execute_next_step)                                        │
│       │                                                                     │
│       ▼                                                                     │
│  ┌─────────────────────────────────────────────────────────┐                │
│  │ ¿Es nodo terminal o nil?                                │                │
│  │   SÍ → complete_workflow()                              │                │
│  │   NO → obtener tipo de nodo                             │                │
│  └─────────────────────────────────────────────────────────┘                │
│       │                                                                     │
│       ├─── :step ──────► execute_graph_step()                               │
│       │                      │                                              │
│       │                      ▼                                              │
│       │                  validate → execute → advance_to_next_node          │
│       │                                                                     │
│       ├─── :branch ────► handle_branch_node()                               │
│       │                      │                                              │
│       │                      ▼                                              │
│       │                  evaluar condition.(state)                          │
│       │                      │                                              │
│       │                      ├── true  → seguir path A                      │
│       │                      └── false → seguir path B                      │
│       │                                                                     │
│       └─── :join ──────► advance_to_next_node()                             │
│                              │                                              │
│                              ▼                                              │
│                          continuar al siguiente nodo                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Niveles de Complejidad (Roadmap)

| Nivel | Descripción | Estado |
|-------|-------------|--------|
| **1. Lineal** | Lista de steps secuenciales | ✅ Implementado |
| **2. Branching Simple** | Bifurcaciones condicionales | ✅ Implementado |
| **3. DAG Completo** | Paralelos + joins complejos | 🔮 Futuro |
| **4. BPMN Completo** | Loops, subprocesses, timers | 🔮 Futuro (si necesario) |

---

## Consecuencias

### Positivas

1. **Workflows Realistas**: Soporta casos de negocio reales
2. **Retrocompatibilidad**: Workflows existentes funcionan sin cambios
3. **Extensibilidad**: Base sólida para paralelos y DAGs futuros
4. **Visualizable**: Grafos se pueden renderizar fácilmente
5. **Testeable**: Cada path del branch se puede testear aisladamente

### Negativas

1. **Complejidad Adicional**: Más código en WorkflowActor
2. **Debugging Más Complejo**: Flujos no lineales son más difíciles de seguir
3. **Persistencia Más Rica**: Hay que guardar `executed_nodes` y `current_node_id`

### Mitigaciones

| Negativa | Mitigación |
|----------|------------|
| Complejidad | Documentación clara, separación en módulos |
| Debugging | Eventos de branch_taken, visualización en dashboard |
| Persistencia | Campos adicionales en Mnesia, migración automática |

---

## Alternativas Consideradas

### 1. Skip Guards en Steps

```elixir
def should_execute?(state) do
  state.approved == true
end
```

**Pros**: Simple, sin cambios al motor
**Contras**: No permite paths divergentes, solo saltos

**Descartada**: Demasiado limitada

### 2. Máquina de Estados (FSM)

```elixir
defstruct state: :pending, transitions: %{
  pending: [:validating],
  validating: [:approved, :rejected],
  ...
}
```

**Pros**: Modelo formal, bien establecido
**Contras**: Más complejo, diferente paradigma mental

**Descartada**: Sobre-ingeniería para nuestro caso

### 3. Grafos con Evaluación Lazy

```elixir
def graph do
  %{
    start: fn -> ValidateIdentity end,
    ValidateIdentity: fn state -> 
      if state.valid, do: CheckCredit, else: Reject
    end,
    ...
  }
end
```

**Pros**: Máxima flexibilidad
**Contras**: Difícil de visualizar, testear, mantener

**Descartada**: Demasiado dinámico

### 4. Grafos Declarativos (Elegida)

**Pros**: Balance entre flexibilidad y estructura
**Contras**: Requiere DSL para definición compleja

**Elegida**: Mejor balance complejidad/funcionalidad

---

## Ejemplos de Uso

### Workflow Lineal (Retrocompatible)

```elixir
defmodule SimpleWorkflow do
  @behaviour Beamflow.Workflows.Workflow

  def steps, do: [Step1, Step2, Step3]

  def graph do
    Beamflow.Workflows.Graph.from_linear_steps(steps())
  end

  def has_branching?, do: false
end
```

### Workflow con Branching

```elixir
defmodule ApprovalWorkflow do
  alias Beamflow.Workflows.Graph

  def graph do
    Graph.new()
    |> Graph.add_step("validate", ValidateStep)
    |> Graph.add_step("approve", ApproveStep)
    |> Graph.add_branch("decision", &(&1.approved))
    |> Graph.add_step("success", SuccessEmail)
    |> Graph.add_step("failure", FailureEmail)
    |> Graph.add_step("close", CloseCase)
    |> Graph.set_start("validate")
    |> Graph.connect("validate", "approve")
    |> Graph.connect("approve", "decision")
    |> Graph.connect_branch("decision", "success", true)
    |> Graph.connect_branch("decision", "failure", false)
    |> Graph.connect("success", "close")
    |> Graph.connect("failure", "close")
    |> Graph.set_end("close")
  end

  def has_branching?, do: true
end
```

---

## Referencias

- [Temporal.io Workflow Design](https://docs.temporal.io/workflows)
- [AWS Step Functions](https://docs.aws.amazon.com/step-functions/)
- [Cadence Workflow Engine](https://cadenceworkflow.io/)
- [BPMN 2.0 Specification](https://www.omg.org/spec/BPMN/2.0/)
