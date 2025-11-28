# ADR-009: Dashboard de Analytics y Sistema Visual

## Estado
**Aceptado** - Noviembre 2025

## Contexto

Con la implementación del motor de workflows (ADR-001 a ADR-008), surgió la necesidad de una interfaz visual que permita:

1. **Monitorear** workflows en tiempo real
2. **Debuggear** fallos y comportamiento de compensaciones
3. **Analizar** métricas históricas y tendencias
4. **Demostrar** las capacidades del sistema a stakeholders

### Requisitos Identificados

| Requisito | Prioridad | Justificación |
|-----------|-----------|---------------|
| Tiempo real | Alta | Ver cambios de estado instantáneamente |
| Sin recarga | Alta | UX fluida, no perder contexto |
| Visualización de grafos | Media | Entender flujo de workflows |
| Métricas históricas | Media | Análisis post-mortem |
| Debugging temporal | Alta | "Rebobinar" para entender fallos |
| API programática | Media | Integración con herramientas externas |

## Decisión

Implementamos un **Dashboard Visual Completo** usando Phoenix LiveView con las siguientes decisiones arquitectónicas:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Dashboard Visual Architecture                         │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         Phoenix Router                               │   │
│  │   /workflows → Explorer | /workflows/:id → Details | /graph → Graph │   │
│  │   /analytics → Analytics | /api/* → REST Controllers                │   │
│  └───────────────────────────────┬─────────────────────────────────────┘   │
│                                  │                                          │
│  ┌───────────────────────────────▼─────────────────────────────────────┐   │
│  │                      LiveView Components                             │   │
│  │                                                                      │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │   │
│  │  │ Explorer     │  │ Details      │  │ Graph        │  │ Analytics│ │   │
│  │  │              │  │              │  │              │  │          │ │   │
│  │  │ • Filters    │  │ • Timeline   │  │ • SVG Nodes  │  │ • KPIs   │ │   │
│  │  │ • Search     │  │ • Events     │  │ • Edges      │  │ • Charts │ │   │
│  │  │ • Streaming  │  │ • Attempts   │  │ • Replay     │  │ • Trends │ │   │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └────┬─────┘ │   │
│  │         │                 │                 │                │       │   │
│  │         └─────────────────┴────────┬────────┴────────────────┘       │   │
│  │                                    │                                 │   │
│  └────────────────────────────────────┼─────────────────────────────────┘   │
│                                       │                                      │
│  ┌────────────────────────────────────▼─────────────────────────────────┐   │
│  │                        Phoenix PubSub                                 │   │
│  │                                                                       │   │
│  │   Topics:                                                             │   │
│  │   • workflow:{id}    → Updates de workflow específico                │   │
│  │   • workflows:list   → Nuevos workflows / cambios de estado          │   │
│  │   • analytics:update → Cambios en métricas agregadas                 │   │
│  └────────────────────────────────────┬─────────────────────────────────┘   │
│                                       │                                      │
│  ┌────────────────────────────────────▼─────────────────────────────────┐   │
│  │                     Storage & Analytics Layer                         │   │
│  │                                                                       │   │
│  │   WorkflowStore (Mnesia)  ←→  WorkflowAnalytics (Cálculos)           │   │
│  └───────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decisiones Clave

#### 1. LiveView sobre SPA (React/Vue)

**Decisión**: Usar Phoenix LiveView en lugar de un SPA separado.

**Razones**:
- ✅ **Tiempo real nativo**: WebSockets integrados sin configuración
- ✅ **Estado compartido**: PubSub del mismo runtime
- ✅ **Sin API adicional**: No duplicar endpoints REST
- ✅ **Consistencia de código**: Todo en Elixir
- ✅ **SEO friendly**: Server-side rendering

**Trade-offs aceptados**:
- ⚠️ Latencia de red afecta interactividad
- ⚠️ Sin offline support (aceptable para dashboard interno)

#### 2. SVG sobre Canvas/WebGL para Grafos

**Decisión**: Renderizar el grafo del workflow como SVG inline.

**Razones**:
- ✅ **Interactividad fácil**: CSS hover, clicks nativos
- ✅ **Accesibilidad**: DOM inspectable, screen readers
- ✅ **Exportable**: `phx-click="export_svg"` directo
- ✅ **Estilizable**: Tailwind classes en elementos
- ✅ **Performante**: <100 nodos típicos, no necesita GPU

**Trade-offs**:
- ⚠️ No escala a 1000+ nodos (no es nuestro caso)
- ⚠️ Animaciones complejas requieren JavaScript

**Estructura del SVG**:
```heex
<svg viewBox="0 0 {@canvas_width} {@canvas_height}">
  <!-- Definiciones de gradientes/markers -->
  <defs>
    <marker id="arrowhead" .../>
    <linearGradient id="node-gradient-{status}" .../>
  </defs>
  
  <!-- Conexiones (renderizadas primero, debajo) -->
  <%= for edge <- @edges do %>
    <path d={edge.path} class="edge" marker-end="url(#arrowhead)"/>
  <% end %>
  
  <!-- Nodos (renderizados después, encima) -->
  <%= for node <- @nodes do %>
    <g phx-click="select_node" phx-value-node-id={node.id}>
      <rect class={"node node-#{node.status}"}/>
      <text>{node.label}</text>
    </g>
  <% end %>
</svg>
```

#### 3. Streams para Listas Grandes

**Decisión**: Usar LiveView Streams para el Workflow Explorer.

**Razones**:
- ✅ **Memoria eficiente**: Solo DOM diffs, no estado en servidor
- ✅ **Scroll infinito**: Cargar bajo demanda
- ✅ **Actualizaciones granulares**: `stream_insert` para un solo item

**Implementación**:
```elixir
def mount(_params, _session, socket) do
  {:ok, socket |> stream(:workflows, initial_workflows())}
end

def handle_info({:workflow_updated, wf}, socket) do
  {:noreply, stream_insert(socket, :workflows, wf)}
end
```

#### 4. Modo Replay: Timeline-Based State Reconstruction

**Decisión**: Reconstruir el estado del workflow en cualquier punto temporal a partir de eventos.

**Arquitectura del Replay**:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Replay Mode Architecture                      │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Event Timeline                         │  │
│  │  ─●────●────●────●────●────●────●────●────●────●────●──  │  │
│  │   │    │    │    │    │    │    │    │    │    │    │    │  │
│  │   ▼    ▼    ▼    ▼    ▼    ▼    ▼    ▼    ▼    ▼    ▼    │  │
│  │  start s1  s1   s2   s2   s3   s3   retry s3  done  │  │
│  │        ↳ok  ↳ok  ↳ok  ↳ok  ↳fail↳    ↳ok      │  │
│  └──────────────────────────────────────────────────────────┘  │
│                              │                                  │
│                              ▼                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              State Reconstruction Engine                  │  │
│  │                                                          │  │
│  │  build_state_from_events(events[0..current_index])       │  │
│  │                                                          │  │
│  │  Returns: %{                                             │  │
│  │    status: :running,                                     │  │
│  │    current_step_index: 2,                                │  │
│  │    step_states: %{0 => :completed, 1 => :completed,      │  │
│  │                   2 => :running}                         │  │
│  │  }                                                       │  │
│  └──────────────────────────────────────────────────────────┘  │
│                              │                                  │
│                              ▼                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │               Visual State Update                         │  │
│  │                                                          │  │
│  │  rebuild_nodes_for_replay(socket, replay_state)          │  │
│  │  → Actualiza colores de nodos según step_states          │  │
│  │  → Marca nodo "actual" con animación                     │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**Estado del Replay**:
```elixir
socket
|> assign(
  replay_mode: true,
  replay_timeline: build_replay_timeline(all_events),
  replay_current_index: 0,
  replay_playing: false,
  replay_speed: 1.0,  # 0.5, 1.0, 2.0, 4.0
  replay_timer_ref: nil
)
```

**Controles disponibles**:
- ▶️ Play/Pause - Reproducción automática
- ⏪ Rewind - Volver al inicio
- ◀️▶️ Step - Avanzar/retroceder un evento
- 🎚️ Slider - Saltar a cualquier punto
- ⏱️ Speed - Velocidad de reproducción

#### 5. API REST para Analytics

**Decisión**: Exponer endpoints REST además de LiveView.

**Razones**:
- ✅ Integración con dashboards externos (Grafana, Datadog)
- ✅ Exportación programática (CI/CD pipelines)
- ✅ Consumo desde scripts/notebooks

**Endpoints**:
| Método | Ruta | Rate Limit | Descripción |
|--------|------|------------|-------------|
| GET | `/api/health` | ❌ No | Health check |
| GET | `/api/analytics/summary` | ✅ 60/min | KPIs resumidos |
| GET | `/api/analytics/trends` | ✅ 60/min | Series temporales |
| GET | `/api/analytics/export` | ✅ 60/min | Export CSV/JSON |

**Rate Limiting**:
```elixir
# Plug con ETS para tracking por IP
plug BeamflowWeb.Plugs.RateLimiter,
  max_requests: 60,
  window_ms: 60_000,
  excluded_paths: ["/api/health"]
```

#### 6. Componentes Funcionales Reutilizables

**Decisión**: Extraer UI común a componentes funcionales.

**Componentes creados**:
```elixir
# Badges de estado con colores semánticos
<.workflow_status_badge status={:completed} />
<.workflow_status_badge status={:failed} />

# Cards con métricas
<.metric_card title="Total" value={1234} trend={+5.2} />

# Sparklines SVG inline
<.sparkline data={[10, 15, 8, 22, 18]} />

# Timeline de eventos
<.event_timeline events={@events} />

# Panel de intentos (attempts)
<.attempt_card attempt={attempt} />
```

## Componentes Implementados

### WorkflowExplorerLive
- Lista paginada con streams
- Filtros: status, módulo, fecha
- Búsqueda por ID
- Click navega a detalles

### WorkflowDetailsLive
- Header con estado y acciones
- Timeline de eventos con iconos
- Panel colapsable de intentos
- Botón para ver grafo

### WorkflowGraphLive
- Grafo SVG interactivo
- Layout automático horizontal
- Click en nodos muestra panel lateral
- Modo Replay integrado

### WorkflowAnalyticsLive
- KPIs principales (total, completados, fallidos, rate)
- Gráficos de tendencia temporal
- Distribución por hora del día
- Filtros de rango de tiempo
- Export CSV/JSON

## Alternativas Consideradas

### 1. D3.js para Grafos
- ❌ Complejidad de integración con LiveView
- ❌ Bundle size adicional
- ❌ Re-render conflicts con morphdom

### 2. React/Vue SPA
- ❌ Duplicación de lógica de estado
- ❌ API REST adicional para todo
- ❌ Complejidad de deployment

### 3. Grafana para Analytics
- ❌ Dependencia externa
- ❌ No integrado con el flujo de la app
- ✅ Podría usarse complementariamente vía API

### 4. Canvas para Grafos
- ❌ Pierde accesibilidad DOM
- ❌ Export a imagen más complejo
- ✅ Mejor para 1000+ nodos (no aplica)

## Consecuencias

### Positivas
- ✅ **UX cohesiva**: Todo en una sola app
- ✅ **Tiempo real nativo**: Sin polling ni configuración
- ✅ **Debugging poderoso**: Replay mode único en el mercado
- ✅ **Mantenibilidad**: Un solo lenguaje, un solo paradigma
- ✅ **Demostrable**: Fácil de mostrar capacidades

### Negativas
- ⚠️ **Dependencia de conexión**: Sin WebSocket no hay actualizaciones
- ⚠️ **Curva de aprendizaje**: LiveView tiene sus particularidades
- ⚠️ **Escalabilidad UI**: +100 workflows visibles simultáneos podría degradar

### Mitigaciones
- Streams para listas grandes
- Debounce en filtros de búsqueda
- Paginación en API REST
- Rate limiting para proteger backend

## Métricas de Éxito

| Métrica | Objetivo | Medición |
|---------|----------|----------|
| Tiempo de carga inicial | <2s | Lighthouse |
| Latencia de actualizaciones | <100ms | PubSub timestamps |
| Memoria por conexión | <5MB | :observer |
| Satisfacción de usuarios | >4/5 | Feedback |

## Referencias

- [Phoenix LiveView Docs](https://hexdocs.pm/phoenix_live_view/)
- [LiveView Streams Guide](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#module-streams)
- [ADR-007: Circuit Breaker & Saga](./007-circuit-breaker-saga-pattern.md)
- [ADR-008: Chaos Engineering](./008-chaos-engineering.md)
