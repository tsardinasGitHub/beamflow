ADR: Uso de Mnesia como sistema de persistencia para el estado de workflows

- **Fecha:** 2025-11-27
- **Estado:** ~~Aceptado~~ → **Superseded por [ADR-005](ADR-005-amnesia-migration.md)**
- **Autores:** Taelen Sardiñas (Portfolio Personal)

> ⚠️ **NOTA**: Esta decisión fue reemplazada por ADR-005 que documenta la migración de Mnesia directo a Amnesia DSL.
> La razón principal fue mejorar la mantenibilidad del código con un DSL declarativo y structs tipados.
> Ver [ADR-005-amnesia-migration.md](ADR-005-amnesia-migration.md) para la arquitectura actual.

---
## Nota del Proyecto

**Beamflow** es un proyecto personal de portfolio basado en experiencia real implementando un motor de workflows para una Plataforma de Trámites Vehiculares (Leasing) en producción, donde trabajé como Desarrollador Senior/Arquitecto de Sistemas Distribuidos.

**Objetivo:** Demostrar habilidades profesionales en Elixir/OTP y arquitecturas distribuidas que no puedo exhibir directamente debido a acuerdos de confidencialidad con empleadores privados.

**Caso de Uso Real Replicado:**
En producción se implementó exitosamente:
- **Mnesia:** Configuración de workflows y reglas de negocio
- **RabbitMQ (AMQP):** Orquestación asíncrona con Event-Driven Architecture
- **GenServers:** Integración con microservicios externos (resiliencia y desacoplamiento)
- **Phoenix LiveView:** UI en tiempo real
- **Equipo:** 2 desarrolladores principales bajo alta presión de entrega
- **Resultados:** Tiempo de procesamiento de días → horas, eliminación de errores en documentos, alta robustez ante fallos

---
## Contexto

Beamflow necesita persistir la configuración de workflows, definiciones y metadatos de ejecución.

**Requisitos técnicos:**
- **Alta disponibilidad:** Resiliencia ante fallos durante ejecuciones prolongadas
- **Consistencia:** Mantener la configuración consistente entre lecturas y actualizaciones
- **Rendimiento:** Operaciones rápidas que no impacten la orquestación
- **Distribución:** Soporte para múltiples nodos
- **Simplicidad operacional:** Despliegue sin dependencias externas complejas

**Restricciones del proyecto:**
- Portfolio de demostración técnica (facilidad de evaluación crítica)
- Volumen de datos moderado (configuración, no BigData)
- Diferenciación técnica: mostrar competencia más allá de stacks relacionales tradicionales

---
## Decisión

**Utilizar Mnesia como sistema de persistencia principal para Beamflow.**

**Razones clave:**

1. **Integración nativa:** Parte del ecosistema OTP, sin dependencias externas
2. **Distribución built-in:** Replicación automática entre nodos Erlang
3. **Transacciones ACID:** Garantías de consistencia para configuración de workflows
4. **Rendimiento:** Tablas en RAM para consultas de alta frecuencia
5. **Simplicidad operacional:** Cero setup externo para evaluadores del portfolio
6. **Diferenciación técnica:** Demuestra dominio del ecosistema BEAM más allá de stacks tradicionales
7. **Arquitectura validada:** Replicación exitosa de estrategia probada en producción

---
## Consecuencias

### Positivas:
- Cero dependencias externas (facilita evaluación del portfolio)
- Despliegue simplificado (la BD viaja con la aplicación)
- Rendimiento óptimo (acceso directo en memoria)
- Consistencia garantizada (transacciones ACID)
- Replicación automática entre nodos
- Integración perfecta (API nativa Elixir/Erlang)
- Valida arquitectura empresarial real
- Demuestra versatilidad técnica (modelo no-relacional)

### Negativas:
- Escalabilidad limitada (>500K registros requeriría reevaluación) - *No limitante para portfolio*
- Consultas con QLC en lugar de SQL estándar - *Parte de la demostración técnica*
- Curva de aprendizaje diferente a RDBMS tradicionales
- Herramientas de administración más limitadas vs PostgreSQL/MySQL
- Bloqueos de tabla en escrituras de alta concurrencia

---
## Alternativas consideradas

### PostgreSQL
**Pros:** SQL estándar, excelentes herramientas, escalabilidad probada, gran ecosistema  
**Contras:** Dependencia externa, complejidad operacional, latencia de red, setup complejo para evaluadores  
**Razón de descarte:** No justifica la complejidad para un portfolio; no aporta diferenciación técnica

### ETS (Erlang Term Storage)
**Pros:** Extremadamente rápido, API simple, integración nativa perfecta  
**Contras:** No persistente (datos volátiles), sin transacciones distribuidas, sin replicación  
**Razón de descarte:** No cumple objetivo de demostrar persistencia distribuida

### Redis
**Pros:** Muy rápido, estructuras de datos avanzadas, replicación  
**Contras:** Dependencia externa, modelo key-value simple, sin transacciones ACID complejas  
**Razón de descarte:** Modelo demasiado simple para configuración de workflows; añade dependencia sin valor diferencial BEAM

---
## Revisión futura

Esta decisión es apropiada para el propósito de portfolio. Revisar solo si:

1. El proyecto evoluciona a producción real con >500K registros
2. Se requieren capacidades analíticas SQL complejas
3. Escalabilidad >10-15 nodos en cluster
4. Integración externa requiere acceso directo SQL
5. Auditoría avanzada excede capacidades nativas de Mnesia

**Para el propósito actual:** Mnesia es técnicamente correcta, cumple objetivos de demostración y replica arquitecturas validadas en producción.
