# ADR-010: Estrategia de Almacenamiento por Niveles (Tiered Storage)

## Estado
**Propuesto** - Documentado para implementación futura

## Fecha
2025-11-28

## Contexto

### El Problema

Mnesia, aunque excelente para estado en tiempo real, tiene limitaciones conocidas para almacenamiento a largo plazo:

| Limitación | Valor | Impacto |
|------------|-------|---------|
| Tamaño máximo por tabla | ~2GB (disc_copies) | Historial limitado |
| Requisito de RAM | Todas las keys en memoria | Costo de memoria |
| Escalabilidad de escritura | Degradación con volumen alto | Bottleneck |
| Queries analíticas | No optimizado para OLAP | Analytics lentos |

### Cálculo de Capacidad

```
Workflow promedio en Mnesia:
├── Registro workflow: ~500 bytes
├── 5 eventos promedio: ~1KB
└── Total: ~1.5KB por workflow

Capacidad estimada con límite 2GB:
├── Teórico: ~1.4 millones de workflows
├── Práctico (70% uso seguro): ~1 millón
└── Con retención infinita: Se llena en semanas/meses

Escenario de producción (1000 workflows/día):
├── Día 1: 1.5MB
├── Mes 1: 45MB
├── Año 1: 540MB (aún OK)
└── Año 2+: Riesgo de límite
```

### Requisitos

1. **Workflows activos**: Latencia <1ms (Mnesia ✓)
2. **Histórico**: Retención indefinida para auditoría
3. **Analytics**: Queries complejas sobre millones de registros
4. **Escalabilidad**: Sin límite práctico de almacenamiento
5. **Costo**: Optimizar RAM (cara) vs disco (barato)

## Decisión

Implementar **arquitectura de almacenamiento por niveles (Hot/Warm/Cold)**:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    TIERED STORAGE ARCHITECTURE                      │
│                                                                     │
│  ┌────────────────┐   ┌────────────────┐   ┌────────────────┐      │
│  │   HOT TIER     │   │   WARM TIER    │   │   COLD TIER    │      │
│  │    (Mnesia)    │   │  (PostgreSQL)  │   │  (S3/Glacier)  │      │
│  ├────────────────┤   ├────────────────┤   ├────────────────┤      │
│  │ • Activos      │   │ • 24h - 1 año  │   │ • > 1 año      │      │
│  │ • Últimas 24h  │   │ • Analytics    │   │ • Compliance   │      │
│  │ • <1ms acceso  │   │ • ~10-50ms     │   │ • min-horas    │      │
│  │ • ~500MB max   │   │ • Terabytes    │   │ • Petabytes    │      │
│  └───────┬────────┘   └───────┬────────┘   └───────┬────────┘      │
│          │                    │                    │                │
│          │    Archiver        │    Cold Archiver   │                │
│          │    (hourly)        │    (monthly)       │                │
│          └────────────────────┴────────────────────┘                │
└─────────────────────────────────────────────────────────────────────┘
```

### Tier 1: Hot Storage (Mnesia)

**Contenido:**
- Workflows con estado `running`, `pending`
- Workflows terminados en últimas 24 horas
- Eventos de workflows activos
- Estado de Circuit Breakers, Rate Limiters

**Características:**
- Latencia: <1ms
- Capacidad objetivo: <500MB
- Retención: 24 horas post-completado

### Tier 2: Warm Storage (PostgreSQL)

**Contenido:**
- Workflows archivados (24h - 1 año)
- Todos los eventos históricos
- Vistas materializadas para analytics

**Características:**
- Latencia: 10-50ms
- Capacidad: Terabytes
- Retención: 1 año (configurable)

### Tier 3: Cold Storage (S3/Glacier) - Futuro

**Contenido:**
- Workflows > 1 año
- Compliance y auditoría legal

**Características:**
- Latencia: minutos a horas
- Capacidad: Ilimitada
- Retención: 7+ años (según regulación)

## Implementación Propuesta

### Componente: Archiver

```elixir
defmodule Beamflow.Storage.Archiver do
  @moduledoc """
  GenServer que migra workflows de Mnesia a PostgreSQL.
  
  Ejecuta periódicamente (cada hora por defecto) y:
  1. Identifica workflows candidatos a archivar
  2. Los inserta en PostgreSQL en batch
  3. Los elimina de Mnesia solo si PostgreSQL confirma
  """
  
  use GenServer
  require Logger

  @default_config %{
    # Intervalo entre ejecuciones
    interval_ms: :timer.hours(1),
    
    # Tamaño del batch
    batch_size: 1000,
    
    # Horas después de completado para archivar
    archive_after_hours: 24,
    
    # Estados que pueden archivarse
    archivable_statuses: [:completed, :failed, :abandoned],
    
    # Umbral de uso de Mnesia para archivado urgente
    urgent_threshold_percent: 70
  }

  # ... implementación
end
```

### Componente: Archive Policy

```elixir
defmodule Beamflow.Storage.ArchivePolicy do
  @moduledoc """
  Define las reglas de cuándo un workflow debe archivarse.
  """
  
  @doc """
  Determina si un workflow debe moverse a PostgreSQL.
  
  Criterios (todos deben cumplirse):
  1. Estado terminal (completed, failed, abandoned)
  2. Tiempo desde completado >= archive_after_hours
  
  Criterio urgente (override):
  - Uso de Mnesia > urgent_threshold_percent
  """
  @spec should_archive?(map(), map()) :: boolean()
  def should_archive?(workflow, config) do
    is_terminal?(workflow) and is_old_enough?(workflow, config)
  end
  
  @spec urgent_archive_needed?() :: boolean()
  def urgent_archive_needed? do
    mnesia_usage_percent() > config().urgent_threshold_percent
  end
end
```

### Esquema PostgreSQL

```sql
-- Workflows archivados
CREATE TABLE archived_workflows (
    id VARCHAR(255) PRIMARY KEY,
    workflow_module VARCHAR(255) NOT NULL,
    status VARCHAR(50) NOT NULL,
    workflow_state JSONB NOT NULL,
    current_step_index INTEGER,
    total_steps INTEGER,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    error JSONB,
    metadata JSONB DEFAULT '{}',
    archived_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Particionamiento por fecha para performance
    CONSTRAINT pk_archived PRIMARY KEY (id, completed_at)
) PARTITION BY RANGE (completed_at);

-- Particiones mensuales
CREATE TABLE archived_workflows_2025_11 
    PARTITION OF archived_workflows
    FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');

-- Índices optimizados
CREATE INDEX idx_arch_status ON archived_workflows(status);
CREATE INDEX idx_arch_module ON archived_workflows(workflow_module);
CREATE INDEX idx_arch_completed ON archived_workflows(completed_at DESC);

-- Eventos archivados
CREATE TABLE archived_events (
    id VARCHAR(255),
    workflow_id VARCHAR(255) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    data JSONB,
    timestamp TIMESTAMPTZ,
    archived_at TIMESTAMPTZ DEFAULT NOW(),
    
    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

CREATE INDEX idx_events_workflow ON archived_events(workflow_id);

-- Vista materializada para dashboard
CREATE MATERIALIZED VIEW workflow_daily_stats AS
SELECT 
    DATE(completed_at) as date,
    workflow_module,
    status,
    COUNT(*) as count,
    AVG(EXTRACT(EPOCH FROM (completed_at - started_at))) as avg_duration_sec,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY 
        EXTRACT(EPOCH FROM (completed_at - started_at))
    ) as p95_duration_sec
FROM archived_workflows
WHERE completed_at IS NOT NULL
GROUP BY DATE(completed_at), workflow_module, status
WITH DATA;

-- Refresh programado (via pg_cron o aplicación)
-- REFRESH MATERIALIZED VIEW CONCURRENTLY workflow_daily_stats;
```

### Configuración

```elixir
# config/config.exs
config :beamflow, Beamflow.Storage.Archiver,
  enabled: true,
  interval_ms: :timer.hours(1),
  batch_size: 1000,
  archive_after_hours: 24,
  archivable_statuses: [:completed, :failed, :abandoned],
  urgent_threshold_percent: 70

# config/prod.exs  
config :beamflow, Beamflow.Repo,
  adapter: Ecto.Adapters.Postgres,
  url: System.get_env("DATABASE_URL"),
  pool_size: 10
```

### Migración del Dashboard

El dashboard necesita consultar ambas fuentes:

```elixir
defmodule Beamflow.Storage.UnifiedStore do
  @moduledoc """
  Capa de abstracción que consulta Mnesia y PostgreSQL transparentemente.
  """
  
  @doc """
  Lista workflows combinando ambas fuentes.
  
  - Mnesia: workflows activos y recientes
  - PostgreSQL: histórico
  """
  def list_workflows(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    include_archived = Keyword.get(opts, :include_archived, false)
    
    mnesia_results = WorkflowStore.list_workflows(limit: limit)
    
    if include_archived do
      archived_results = PostgresArchive.list_workflows(limit: limit)
      merge_and_sort(mnesia_results, archived_results, limit)
    else
      mnesia_results
    end
  end
  
  @doc """
  Obtiene un workflow por ID, buscando primero en Mnesia.
  """
  def get_workflow(id) do
    case WorkflowStore.get_workflow(id) do
      {:ok, workflow} -> {:ok, workflow}
      {:error, :not_found} -> PostgresArchive.get_workflow(id)
    end
  end
end
```

## Alternativas Consideradas

### 1. Solo Mnesia con Purga

**Descripción:** Eliminar workflows antiguos sin archivar.

**Rechazado porque:**
- Pérdida de datos históricos
- Sin capacidad de auditoría
- Sin analytics a largo plazo

### 2. Mnesia Fragmentada

**Descripción:** Usar fragmentación nativa de Mnesia para escalar.

**Rechazado porque:**
- Complejidad operacional alta
- No resuelve el límite de RAM
- Queries cross-fragment son lentas

### 3. Solo PostgreSQL

**Descripción:** Eliminar Mnesia, usar solo PostgreSQL.

**Rechazado porque:**
- Perdemos latencia <1ms para workflows activos
- Perdemos integración nativa con OTP
- Perdemos simplicidad de deploy (sin DB externa)

### 4. TimescaleDB

**Descripción:** Usar TimescaleDB en lugar de PostgreSQL vanilla.

**Considerado para futuro:**
- Mejor para time-series (eventos)
- Compresión automática
- Retención policies nativas

### 5. ClickHouse

**Descripción:** Usar ClickHouse para analytics.

**Considerado para futuro:**
- Óptimo para queries analíticas
- Compresión extrema
- Pero: otro sistema que operar

## Consecuencias

### Positivas

1. **Escalabilidad ilimitada**: PostgreSQL puede manejar terabytes
2. **Analytics potentes**: SQL completo, joins, agregaciones
3. **Mnesia optimizado**: Solo datos calientes, baja memoria
4. **Flexibilidad**: Configurable según necesidades
5. **Estándares**: Backups, replicación con herramientas conocidas

### Negativas

1. **Complejidad**: Dos sistemas de storage
2. **Dependencia**: PostgreSQL requerido en producción
3. **Latencia mixta**: Queries históricos más lentos
4. **Desarrollo**: Más código para mantener

### Neutras

1. **Deploy simple sigue siendo posible**: Archiver opcional, deshabilitado por defecto
2. **Migración gradual**: Se puede implementar incrementalmente

## Plan de Implementación

### Fase 1: Fundamentos (v2.0)
- [ ] Agregar Ecto y PostgreSQL como dependencias opcionales
- [ ] Crear esquema de tablas archivadas
- [ ] Implementar Archiver GenServer básico
- [ ] Tests de integración

### Fase 2: Integración (v2.1)
- [ ] UnifiedStore para queries transparentes
- [ ] Actualizar Dashboard para mostrar archivados
- [ ] Métricas de uso de Mnesia
- [ ] Alertas cuando se acerca al límite

### Fase 3: Optimización (v2.2)
- [ ] Vistas materializadas para analytics
- [ ] Particionamiento automático
- [ ] Cold storage a S3 (opcional)
- [ ] Herramientas de administración

## Métricas de Éxito

| Métrica | Objetivo |
|---------|----------|
| Uso de Mnesia | < 500MB constante |
| Latencia workflows activos | < 1ms (sin cambio) |
| Retención histórica | Indefinida |
| Queries analíticos | < 5s para millones de registros |

## Referencias

- [Mnesia User's Guide - Limitations](https://www.erlang.org/doc/apps/mnesia/mnesia_chap7.html)
- [PostgreSQL Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)
- [Tiered Storage Pattern](https://martinfowler.com/articles/patterns-of-distributed-systems/tiered-storage.html)
- ADR-001: Elección de Mnesia como storage principal

## Notas

Este ADR documenta la estrategia para cuando BeamFlow se use en producción con alto volumen. Para demos y desarrollo, la arquitectura actual (solo Mnesia) es suficiente.

La implementación se priorizará cuando:
1. Haya usuarios reportando problemas de capacidad
2. Se prepare para deployment empresarial
3. Se requiera compliance con retención de datos

---

*Última actualización: 2025-11-28*
