# ADR-005: Migración de Mnesia Directo a Amnesia

## Estado
**Aceptado** - 2025-11-29

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

## Plan de Implementación

### Fase 1: Preparación
1. Agregar dependencia Amnesia al `mix.exs`
2. Crear módulo `Beamflow.Database` con definición de tablas
3. Implementar sistema de backup/restore

### Fase 2: Migración
1. Migrar `MnesiaSetup` para usar Amnesia
2. Migrar `WorkflowStore` para usar nuevas queries
3. Migrar `EventStore` 
4. Migrar `IdempotencyStore`
5. Migrar `DeadLetterQueue`

### Fase 3: Limpieza
1. Eliminar código Mnesia directo obsoleto
2. Actualizar tests
3. Documentar nuevo sistema

## Referencias

- [Amnesia GitHub](https://github.com/meh/amnesia)
- [Mnesia User's Guide](https://www.erlang.org/doc/apps/mnesia/users_guide.html)
- Proyecto Leasing - Implementación de referencia
- ADR-003: Decisiones de Persistencia Original
