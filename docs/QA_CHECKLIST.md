# 🧪 Checklist de Testing Manual (QA)

> **Propósito**: Verificación manual de funcionalidades antes de releases  
> **Tiempo estimado**: 30-45 minutos  
> **Última actualización**: Noviembre 2025

---

## 🤖 QA Automático (Recomendado primero)

Antes de ejecutar el checklist manual, ejecuta el script automático:

```bash
# Verificación completa (requiere app corriendo)
mix run scripts/qa_check.exs

# Con detalles
mix run scripts/qa_check.exs --verbose

# Solo secciones específicas
mix run scripts/qa_check.exs --section smoke   # Infraestructura
mix run scripts/qa_check.exs --section api     # Endpoints REST
mix run scripts/qa_check.exs --section workflows  # Workflows
mix run scripts/qa_check.exs --section chaos   # Chaos Mode
```

El script verifica automáticamente:
- ✅ Compilación y Mnesia
- ✅ PubSub y Supervisores
- ✅ Endpoints API con headers de rate limit
- ✅ Creación y estado de workflows
- ✅ ChaosMonkey start/stop/profiles

---

## 📋 Pre-requisitos

- [ ] Aplicación iniciada con `mix phx.server`
- [ ] Mnesia inicializado (tablas creadas)
- [ ] Navegador abierto en `http://localhost:4000`
- [ ] QA automático ejecutado: `mix run scripts/qa_check.exs`
- [ ] Datos de demo creados desde `/demo` o con script

---

## 🔥 Smoke Tests (5 min)

Verificación rápida de que nada está roto.

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 1.1 | App inicia | `mix phx.server` | Sin errores de compilación | ☐ |
| 1.2 | Dashboard carga | Navegar a `/` | Lista de workflows visible | ☐ |
| 1.3 | Sin errores JS | Abrir DevTools → Console | Sin errores rojos | ☐ |
| 1.4 | WebSocket conecta | Network → WS | LiveView conectado | ☐ |
| 1.5 | Demo script | `mix run scripts/demo_setup.exs` | 10 workflows creados | ☐ |

---

## 📂 Workflow Explorer (10 min)

### Listado y Navegación

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 2.1 | Lista vacía | Sin workflows creados | Mensaje "No hay workflows" | ☐ |
| 2.2 | Lista con datos | Crear 3+ workflows | Aparecen en la lista | ☐ |
| 2.3 | Tiempo real | Crear workflow desde IEx | Aparece sin refrescar | ☐ |
| 2.4 | Colores correctos | Ver lista | Verde=completed, Rojo=failed | ☐ |
| 2.5 | Click navega | Click en un workflow | Abre vista de detalles | ☐ |

### Filtros

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 2.6 | Filtro por status | Seleccionar "Completed" | Solo muestra completados | ☐ |
| 2.7 | Filtro por módulo | Seleccionar módulo | Solo ese módulo | ☐ |
| 2.8 | Búsqueda por ID | Escribir ID parcial | Filtra correctamente | ☐ |
| 2.9 | Limpiar filtros | Click "Limpiar" | Vuelve a mostrar todos | ☐ |
| 2.10 | Combinar filtros | Status + Módulo | Intersección correcta | ☐ |

### Paginación/Scroll

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 2.11 | Scroll infinito | Crear 50+ workflows, scroll | Carga más al llegar abajo | ☐ |
| 2.12 | Performance | 100+ workflows | Sin lag visible | ☐ |

---

## 📄 Workflow Details (10 min)

### Header y Estado

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 3.1 | ID visible | Abrir detalles | ID del workflow visible | ☐ |
| 3.2 | Status badge | Ver header | Color correcto según estado | ☐ |
| 3.3 | Módulo visible | Ver header | Nombre del módulo workflow | ☐ |
| 3.4 | Timestamps | Ver metadata | Fechas de inicio/fin visibles | ☐ |
| 3.5 | Navegación atrás | Click "← Volver" | Regresa al explorer | ☐ |

### Timeline de Eventos

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 3.6 | Eventos visibles | Ver timeline | Lista de eventos ordenada | ☐ |
| 3.7 | Iconos correctos | Ver iconos | ✓=success, ✗=error, ↺=retry | ☐ |
| 3.8 | Timestamps | Ver cada evento | Hora precisa | ☐ |
| 3.9 | Detalles expandibles | Click en evento | Muestra metadata | ☐ |
| 3.10 | Orden cronológico | Revisar orden | Primero → Último | ☐ |

### Panel de Intentos

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 3.11 | Sin intentos | Workflow sin retries | No muestra sección | ☐ |
| 3.12 | Con intentos | Workflow con retries | Sección visible | ☐ |
| 3.13 | Expandir/colapsar | Toggle panel | Muestra/oculta detalles | ☐ |
| 3.14 | Info de cada intento | Ver intento | Timestamp, resultado, error | ☐ |

---

## 🔷 Workflow Graph (10 min)

### Renderizado del Grafo

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 4.1 | Acceso al grafo | Click "Ver Grafo" | Vista de grafo se abre | ☐ |
| 4.2 | Nodos visibles | Ver SVG | Todos los steps como nodos | ☐ |
| 4.3 | Conexiones | Ver SVG | Flechas entre nodos | ☐ |
| 4.4 | Colores estados | Ver nodos | Verde/azul/rojo/gris correctos | ☐ |
| 4.5 | Labels legibles | Ver texto | Nombres de módulos visibles | ☐ |

### Interactividad

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 4.6 | Click en nodo | Click cualquier nodo | Panel lateral se abre | ☐ |
| 4.7 | Detalles del nodo | Ver panel | Nombre, estado, timing | ☐ |
| 4.8 | Cerrar panel | Click X o fuera | Panel se cierra | ☐ |
| 4.9 | Hover effect | Mouse sobre nodo | Resaltado visual | ☐ |
| 4.10 | Export SVG | Click "Exportar SVG" | Descarga archivo .svg | ☐ |

### Modo Replay 🎬

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 4.11 | Activar replay | Click "Replay" | Controles aparecen | ☐ |
| 4.12 | Play | Click ▶️ | Animación automática | ☐ |
| 4.13 | Pause | Click ⏸ | Animación se detiene | ☐ |
| 4.14 | Step forward | Click ▶️ (step) | Avanza un evento | ☐ |
| 4.15 | Step backward | Click ◀️ | Retrocede un evento | ☐ |
| 4.16 | Rewind | Click ⏪ | Vuelve al inicio | ☐ |
| 4.17 | Slider | Arrastrar slider | Salta a posición | ☐ |
| 4.18 | Velocidad 0.5x | Seleccionar 0.5x | Más lento | ☐ |
| 4.19 | Velocidad 4x | Seleccionar 4x | Más rápido | ☐ |
| 4.20 | Marcadores | Ver timeline | Rojos=error, Amarillos=retry | ☐ |
| 4.21 | Info evento actual | Ver panel | Descripción del evento | ☐ |
| 4.22 | Salir replay | Click "Salir" | Vuelve a vista normal | ☐ |

---

## 📊 Analytics Dashboard (10 min)

### KPIs

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 5.1 | Acceso | Navegar a /analytics | Dashboard carga | ☐ |
| 5.2 | Total workflows | Ver KPI | Número correcto | ☐ |
| 5.3 | Completados | Ver KPI | Número verde | ☐ |
| 5.4 | Fallidos | Ver KPI | Número rojo | ☐ |
| 5.5 | Success rate | Ver KPI | Porcentaje correcto | ☐ |
| 5.6 | Actualización | Crear workflow | KPIs actualizan | ☐ |

### Gráficos

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 5.7 | Tendencia temporal | Ver gráfico | Línea con datos | ☐ |
| 5.8 | Distribución horaria | Ver gráfico | Barras por hora | ☐ |
| 5.9 | Filtro de tiempo | Cambiar rango | Gráficos actualizan | ☐ |
| 5.10 | Tooltips | Hover en gráfico | Muestra valores | ☐ |

### Exportación

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 5.11 | Export CSV | Click "Exportar CSV" | Descarga archivo | ☐ |
| 5.12 | Export JSON | Click "Exportar JSON" | Descarga archivo | ☐ |
| 5.13 | Contenido CSV | Abrir archivo | Headers y datos correctos | ☐ |
| 5.14 | Contenido JSON | Abrir archivo | Estructura válida | ☐ |

---

## 🔌 API REST (5 min)

### Endpoints

| # | Test | Comando | Esperado | ✅ |
|---|------|---------|----------|---|
| 6.1 | Health | `curl /api/health` | Status 200, `{"status":"ok"}` | ☐ |
| 6.2 | Summary | `curl /api/analytics/summary` | Status 200, KPIs JSON | ☐ |
| 6.3 | Trends | `curl /api/analytics/trends` | Status 200, series JSON | ☐ |
| 6.4 | Export JSON | `curl /api/analytics/export?format=json` | Datos completos | ☐ |

### Rate Limiting

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 6.5 | Headers presentes | Hacer request | `X-RateLimit-*` headers | ☐ |
| 6.6 | Limit | Ver header | `X-RateLimit-Limit: 60` | ☐ |
| 6.7 | Remaining decrece | Múltiples requests | Remaining baja | ☐ |
| 6.8 | Health sin rate limit | Spam /api/health | Siempre responde 200 | ☐ |
| 6.9 | 429 al exceder | 61 requests en 1 min | Status 429 | ☐ |

---

## 💥 Chaos Mode (5 min)

### Activación

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 7.1 | Iniciar gentle | `ChaosMonkey.start(:gentle)` | Log de activación | ☐ |
| 7.2 | Iniciar moderate | `ChaosMonkey.start(:moderate)` | Log de activación | ☐ |
| 7.3 | Iniciar aggressive | `ChaosMonkey.start(:aggressive)` | Log de activación | ☐ |
| 7.4 | Stats | `ChaosMonkey.stats()` | Estadísticas correctas | ☐ |
| 7.5 | Stop | `ChaosMonkey.stop()` | Se detiene | ☐ |
| 7.6 | Via script | `demo_setup.exs --chaos` | Chaos activado automáticamente | ☐ |

### Comportamiento

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 7.6 | Fallos inyectados | Crear workflows con chaos | Algunos fallan | ☐ |
| 7.7 | Recuperación | Workflows con retries | Algunos se recuperan | ☐ |
| 7.8 | Compensaciones | Ver workflow fallido | Saga compensó | ☐ |
| 7.9 | Dashboard refleja | Ver analytics | Métricas reflejan fallos | ☐ |

---

## 🎬 Demo Mode (5 min)

### Acceso y Navegación

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 8.1 | Acceso directo | Navegar a `/demo` | Página Demo Mode carga | ☐ |
| 8.2 | Título visible | Ver header | "🎬 BeamFlow Demo Mode" | ☐ |
| 8.3 | Presets visibles | Ver panel izquierdo | 5 botones preset | ☐ |
| 8.4 | Log visible | Ver panel derecho | Área de log actividad | ☐ |

### Generación de Workflows

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 8.5 | Inicio Rápido | Click "🚀 Inicio Rápido" | 1 workflow creado | ☐ |
| 8.6 | Lote x10 | Click "📦 Lote x10" | 10 workflows creados | ☐ |
| 8.7 | Modo Chaos | Click "💥 Modo Chaos" | 5 workflows + chaos | ☐ |
| 8.8 | Demo Completa | Click "🎭 Demo Completa" | 20 workflows | ☐ |
| 8.9 | Stress Test | Click "🔥 Stress Test" | 50+ workflows | ☐ |

### Funcionalidad

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 8.10 | Toggle Chaos | Activar/desactivar chaos | Switch funciona | ☐ |
| 8.11 | Contador workflows | Crear workflows | Contador incrementa | ☐ |
| 8.12 | Log actualiza | Ejecutar preset | Log muestra acciones | ☐ |
| 8.13 | Navegación Explorer | Click "Ver Explorer" | Redirige correctamente | ☐ |
| 8.14 | Workflows visibles | Ir a Explorer | Workflows de demo aparecen | ☐ |

---

## 🐛 Edge Cases (5 min)

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 8.1 | Workflow sin eventos | Crear y detener inmediato | No crashea UI | ☐ |
| 8.2 | Grafo sin steps | Workflow con 0 steps | Mensaje apropiado | ☐ |
| 8.3 | ID muy largo | Workflow con ID extenso | No rompe layout | ☐ |
| 8.4 | Reconexión | Perder y recuperar red | LiveView reconecta | ☐ |
| 8.5 | Tab inactivo | Abrir en background | Actualiza al volver | ☐ |
| 8.6 | Múltiples tabs | Abrir 2 tabs | Ambas sincronizan | ☐ |

---

## 📱 Responsive (Opcional)

| # | Test | Pasos | Esperado | ✅ |
|---|------|-------|----------|---|
| 9.1 | Mobile (375px) | DevTools responsive | Layout adaptado | ☐ |
| 9.2 | Tablet (768px) | DevTools responsive | Layout adaptado | ☐ |
| 9.3 | Desktop (1920px) | Pantalla grande | Aprovecha espacio | ☐ |
| 9.4 | Grafo en mobile | Ver grafo en mobile | Scrolleable/zoomable | ☐ |

---

## ✅ Resumen de Ejecución

| Sección | Tests | Pasaron | Fallaron | Notas |
|---------|-------|---------|----------|-------|
| Smoke Tests | 5 | ☐ | ☐ | |
| Explorer | 12 | ☐ | ☐ | |
| Details | 14 | ☐ | ☐ | |
| Graph | 22 | ☐ | ☐ | |
| Analytics | 14 | ☐ | ☐ | |
| API REST | 9 | ☐ | ☐ | |
| Chaos Mode | 10 | ☐ | ☐ | |
| Demo Mode | 14 | ☐ | ☐ | |
| Edge Cases | 6 | ☐ | ☐ | |
| **TOTAL** | **106** | ☐ | ☐ | |

---

## 🐞 Bugs Encontrados

| # | Sección | Descripción | Severidad | Issue |
|---|---------|-------------|-----------|-------|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |

---

## 📝 Notas del QA

**Fecha de ejecución:**  
**Ejecutado por:**  
**Versión/Commit:**  
**Ambiente:**  

**Observaciones generales:**

```
[Espacio para notas adicionales]
```

---

> **Recordatorio**: Este checklist complementa pero NO reemplaza los 334 tests automatizados. Ejecutar `mix test` antes de QA manual. También recomendamos ejecutar `mix run scripts/qa_check.exs` primero para validación automática.
