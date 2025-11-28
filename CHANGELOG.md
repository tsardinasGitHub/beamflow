# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

#### Phase 4: Dashboard Visual y Analytics
- **Workflow Explorer** (`WorkflowExplorerLive`)
  - Lista interactiva de workflows con LiveView Streams
  - Filtros por estado, módulo y búsqueda por ID
  - Actualizaciones en tiempo real vía PubSub
  - Badges de colores según estado (completed, failed, running)

- **Workflow Details** (`WorkflowDetailsLive`)
  - Timeline visual de eventos con iconos y colores
  - Panel de intentos (attempts) para steps con retries
  - Metadata expandible por evento
  - Navegación fluida al grafo

- **Workflow Graph** (`WorkflowGraphLive`)
  - Visualización SVG interactiva del workflow como grafo
  - Nodos con colores dinámicos según estado de ejecución
  - Click en nodos muestra panel lateral de detalles
  - Exportación a SVG
  - **Modo Replay** 🎬: Debugger visual de workflows
    - Timeline con controles de reproducción (play/pause/rewind)
    - Navegación step-by-step hacia adelante y atrás
    - Slider para saltar a cualquier punto temporal
    - Velocidades ajustables (0.5x, 1x, 2x, 4x)
    - Marcadores visuales de errores/retries/compensaciones
    - Reconstrucción de estado en tiempo seleccionado

- **Analytics Dashboard** (`WorkflowAnalyticsLive`)
  - KPIs en tiempo real (total, completados, fallidos, success rate)
  - Gráficos de tendencia temporal con sparklines SVG
  - Distribución de ejecuciones por hora del día
  - Filtros de rango de tiempo
  - Exportación CSV/JSON

- **API REST para Analytics**
  - `GET /api/health` - Health check (sin rate limit)
  - `GET /api/analytics/summary` - KPIs resumidos
  - `GET /api/analytics/trends` - Series temporales para gráficos
  - `GET /api/analytics/export` - Exportación completa (CSV/JSON)

- **Rate Limiting**
  - Plug de rate limiting basado en ETS
  - 60 requests por minuto por IP
  - Headers estándar: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`
  - Exclusión configurable de rutas (ej: health check)

- **Componentes UI Reutilizables**
  - `workflow_status_badge/1` - Badge de estado con colores semánticos
  - `metric_card/1` - Card de métricas con tendencia
  - `sparkline/1` - Gráfico de línea inline SVG
  - `event_timeline/1` - Timeline de eventos
  - `attempt_card/1` - Card de intento con detalles

#### Chaos Engineering (Phase 3)
- ChaosMonkey con perfiles configurables (gentle, moderate, aggressive)
- FaultInjector para inyección opt-in en steps
- IdempotencyValidator para validar idempotencia de operaciones
- Integración con AlertSystem para notificaciones

#### Saga Pattern y Resiliencia (Phase 3)
- Compensaciones automáticas en caso de fallo
- Circuit Breaker para protección de servicios externos
- Dead Letter Queue (DLQ) con UI de gestión
- Sistema de alertas con severidades y rate limiting

### Changed
- WorkflowActor ahora emite eventos granulares para todas las operaciones
- Mejoras en métricas de Telemetry con más dimensiones
- PubSub refactorizado para tópicos más específicos

### Fixed
- Rate limiter usa `unique_integer()` para conteo preciso en concurrencia alta
- Agrupación correcta de handlers `handle_info` en LiveViews

### Documentation
- ADR-009: Dashboard de Analytics y Sistema Visual
- Guía de demostración para reclutadores (`docs/DEMO_GUIDE.md`)
- Checklist de QA para testing manual (`docs/QA_CHECKLIST.md`)
- Análisis de documentación (`docs/DOCUMENTATION_REVIEW.md`)

### Security
- Rate limiting en endpoints de API
- Validación de parámetros en controllers

## [0.1.0] - 2025-11-27

### Added
- Initial release of Beamflow
- Core workflow orchestration engine with GenServer actors
- Phoenix LiveView foundation
- Mnesia-based persistence layer
- Real-time telemetry and monitoring
- Chaos mode infrastructure for resilience testing
- Comprehensive development tooling:
  - Credo for code quality
  - Dialyzer for type checking
  - Sobelow for security scanning
  - ExCoveralls for test coverage
  - ExDoc for documentation generation
- Environment variable management with Dotenvy
- CI/CD pipeline with GitHub Actions
- Development guides and documentation
- Architecture Decision Records (ADR 001-008)

[Unreleased]: https://github.com/tsardinasGitHub/beamflow/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tsardinasGitHub/beamflow/releases/tag/v0.1.0
