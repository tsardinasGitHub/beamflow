# ADR-005: Migración de Mnesia Directo a Amnesia

## Estado
**Completado** - 2025-11-29

## Resumen de Implementación

| Componente | Estado | Descripción |
|------------|--------|-------------|
| `Beamflow.Database` | ✅ | 4 tablas definidas con `deftable` (Workflow, Event, Idempotency, DeadLetterEntry) |
| `Database.Query` | ✅ | CRUD genérico + queries específicas |
| `Database.Setup` | ✅ | Inicialización y diagnóstico |
| `Database.Migration` | ✅ | Sistema backup/restore |
| `WorkflowStore` | ✅ | Migrado usando adapter pattern |
| `IdempotencyStore` | ✅ | Migrado usando adapter pattern |
| `DeadLetterQueue` | ✅ | Migrado usando adapter pattern |
| `MnesiaSetup` (legacy) | 🗑️ | Eliminado |
| **Tests** | ✅ | **381 tests, 0 failures** |

## Contexto

Beamflow utiliza Mnesia directamente para persistencia de datos (workflows, eventos, idempotencia, DLQ). Actualmente la implementación tiene las siguientes características:

### Situación Actual
```elixir
# Creación manual de tablas
:mnesia.create_table(:beamflow_workflows, [
  attributes: [:id, :definition, :status, :created_at, :updated_at],
  type: :set,
  disc_copies: [node()]
])

# Queries con tuplas raw
:mnesia.transaction(fn ->
  :mnesia.match_object({:beamflow_workflows, id, :_, :_, :_, :_})
end)
```

### Problemas Identificados
1. **Código verbose y propenso a errores** - Las operaciones con Mnesia requieren mucho boilerplate
2. **Sin sistema de migración** - Cambios en el schema requieren destruir y recrear tablas manualmente
3. **Pérdida de datos en migraciones** - No hay backup/restore automático
4. **Tuplas raw** - Difícil de mantener, no hay structs tipados
5. **Sin serialización JSON** - Requiere implementar Jason.Encoder manualmente
6. **Queries complejas** - `:mnesia.select` es verbose y difícil de leer
7. **Testing difícil** - Trabajar con tuplas complica los tests

### Referencia de Proyecto Similar
El proyecto Leasing (mismo equipo) utiliza Amnesia exitosamente con:
- DSL declarativo para tablas
- Backup/restore automático en migraciones
- Jason.Encoder inline
- Queries con `where`, `match`, `stream`
- Structs tipados automáticos

## Decisión

**Migrar de Mnesia directo a Amnesia** para todas las operaciones de persistencia.

### Justificación

1. **Escalabilidad de código**
   - Código más mantenible y legible
   - Menor curva de aprendizaje para nuevos desarrolladores
   - DSL declarativo reduce errores

2. **Evolución del schema**
   - Amnesia facilita backup/restore durante migraciones
   - Menos riesgo de pérdida de datos

3. **Productividad**
   - Menos código boilerplate
   - Queries más expresivas
   - Structs tipados automáticos

4. **Consistencia**
   - Alineación con otros proyectos del equipo (Leasing)
   - Patrones probados en producción

## Alternativas Consideradas

### 1. Mantener Mnesia Directo + Mejoras
**Rechazado** porque:
- Requiere implementar manualmente todo lo que Amnesia ya proporciona
- Mayor costo de mantenimiento a largo plazo
- No resuelve el problema de migración de schema

### 2. Migrar a Ecto + Base de Datos Relacional
**Rechazado** porque:
- Beamflow está diseñado para ser self-contained (sin dependencias externas)
- Mnesia/Amnesia proporciona distribución nativa de Erlang/OTP
- Cambio arquitectural demasiado grande

### 3. Usar ETS en lugar de Mnesia
**Rechazado** porque:
- ETS es solo en memoria (sin persistencia)
- No soporta transacciones
- No escala a múltiples nodos

## Consecuencias

### Positivas
- ✅ Código más limpio y mantenible
- ✅ Sistema de backup/restore para migraciones
- ✅ Structs tipados con Jason.Encoder
- ✅ Queries expresivas con DSL
- ✅ Consistencia con proyecto Leasing
- ✅ Menor riesgo de bugs

### Negativas
- ⚠️ Nueva dependencia (`amnesia ~> 0.2.8`)
- ⚠️ Requiere migración de código existente
- ⚠️ Curva de aprendizaje inicial para el equipo

### Riesgos y Mitigaciones
| Riesgo | Mitigación |
|--------|------------|
| Pérdida de datos durante migración | Implementar backup antes de migrar |
| Incompatibilidad con código existente | Migración gradual, mantener compatibilidad temporal |
| Bugs en nueva implementación | Tests exhaustivos antes de producción |

## Plan de Implementación (Completado)

### Fase 1: Preparación ✅
1. ✅ Agregada dependencia `{:amnesia, "~> 0.2.8"}` al `mix.exs`
2. ✅ Creado `lib/beamflow/database.ex` con 4 tablas: Workflow, Event, Idempotency, DeadLetterEntry
3. ✅ Implementado `lib/beamflow/database/migration.ex` con backup_all_tables/0 y restore_from_backup/1

### Fase 2: Migración ✅
1. ✅ Creado `lib/beamflow/database/setup.ex` - reemplaza MnesiaSetup
2. ✅ Creado `lib/beamflow/database/query.ex` - API unificada de queries
3. ✅ Migrado `WorkflowStore` usando adapter pattern (API pública sin cambios)
4. ✅ Migrado `IdempotencyStore` usando adapter pattern
5. ✅ Migrado `DeadLetterQueue` usando adapter pattern

### Fase 3: Limpieza ✅
1. ✅ Eliminado `lib/beamflow/storage/mnesia_setup.ex`
2. ✅ Creados 47 tests específicos para Amnesia (setup_test, query_test, tables_test)
3. ✅ Todos los 381 tests del proyecto pasando
4. ✅ Documentación actualizada

### Archivos Creados
```
lib/beamflow/
├── database.ex                    # Definición de tablas con deftable
└── database/
    ├── query.ex                   # CRUD y queries específicas
    ├── setup.ex                   # Inicialización (init/1, reset!/1, status/0)
    └── migration.ex               # Backup/restore

test/beamflow/database/
├── setup_test.exs                 # 7 tests
├── query_test.exs                 # 26 tests
└── tables_test.exs                # 14 tests
```

### Correcciones Aplicadas
- **Tablas :bag**: Agregado `List.flatten/1` para manejar listas anidadas retornadas por Amnesia
- **Sintaxis Enum.filter**: Corregida sintaxis de funciones anónimas en filtros

## Referencias

- [Amnesia GitHub](https://github.com/meh/amnesia)
- [Mnesia User's Guide](https://www.erlang.org/doc/apps/mnesia/users_guide.html)
- Proyecto Leasing - Implementación de referencia
- ADR-003: Decisiones de Persistencia Original
