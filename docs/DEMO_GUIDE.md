# 🎬 Guía de Demostración - BEAMFlow

> **Tiempo estimado**: 5-10 minutos  
> **Audiencia**: Reclutadores, evaluadores técnicos, stakeholders  
> **Prerequisito**: Aplicación corriendo en `http://localhost:4000`

---

## 🚀 Inicio Rápido (30 segundos)

### ¿Qué es BEAMFlow?

BEAMFlow es un **motor de orquestación de workflows distribuido** construido con Elixir/OTP que demuestra:

| Capacidad | Descripción |
|-----------|-------------|
| 🔄 **Auto-recuperación** | Los procesos que fallan se reinician automáticamente |
| 📊 **Tiempo Real** | Dashboard actualiza sin refrescar la página |
| 🎯 **Saga Pattern** | Compensaciones automáticas cuando algo falla |
| 💥 **Chaos Engineering** | Modo de prueba que inyecta fallos aleatorios |
| 🎬 **Debugging Visual** | "Rebobinar" workflows para entender qué pasó |

---

## 📋 Demo Paso a Paso

### Paso 1: Abrir el Dashboard (30 seg)

1. Navegar a `http://localhost:4000`
2. Verás el **Workflow Explorer** con la lista de workflows

**Qué observar:**
- ✅ Badges de colores por estado (verde=completado, rojo=fallido)
- ✅ Contador de workflows activos
- ✅ Filtros en la barra lateral

---

### Paso 2: Crear Workflows de Prueba (1 min)

Abre una terminal y ejecuta:

```bash
iex -S mix
```

Dentro de IEx, pega estos comandos:

```elixir
# Crear 5 solicitudes de seguro vehicular
alias Beamflow.Engine.WorkflowSupervisor
alias Beamflow.Domains.Insurance.InsuranceWorkflow

for i <- 1..5 do
  WorkflowSupervisor.start_workflow(
    InsuranceWorkflow,
    "demo-#{i}",
    %{
      "applicant_name" => "Cliente #{i}",
      "dni" => String.pad_leading("#{i}", 8, "0"),
      "vehicle_model" => "Auto #{i}",
      "vehicle_year" => "#{2018 + i}",
      "vehicle_plate" => "DEMO-#{i}"
    }
  )
end
```

**Qué observar en el dashboard:**
- ✅ Los workflows aparecen en tiempo real (sin refrescar)
- ✅ El estado cambia de "running" a "completed" o "failed"
- ✅ Las métricas se actualizan automáticamente

---

### Paso 3: Ver Timeline de Eventos (1 min)

1. Click en cualquier workflow de la lista
2. Se abre la vista **Workflow Details**

**Qué observar:**
- ✅ **Timeline** mostrando cada paso ejecutado
- ✅ **Iconos** de color por tipo de evento
- ✅ **Timestamps** de cada acción
- ✅ **Resultado** de cada step (éxito/fallo)

Si hay retries o fallos:
- ✅ Sección **"Intentos"** mostrando cada intento
- ✅ Razón del fallo en cada intento

---

### Paso 4: Visualizar el Grafo (1 min)

1. Click en el botón **"Ver Grafo"** (icono de nodos)
2. Se abre la vista **Workflow Graph**

**Qué observar:**
- ✅ **Nodos** representando cada step del workflow
- ✅ **Colores** indicando estado:
  - 🟢 Verde = Completado
  - 🔵 Azul = Ejecutando
  - 🔴 Rojo = Fallido
  - ⚪ Gris = Pendiente
- ✅ **Flechas** mostrando el flujo entre steps
- ✅ Click en un nodo muestra detalles del step

---

### Paso 5: Modo Replay 🎬 (2 min) - **¡El Feature Estrella!**

1. En la vista del Grafo, click en **"Replay"**
2. Se activa el modo de reproducción

**Controles disponibles:**
- ▶️ **Play/Pause** - Reproducción automática
- ⏪ **Rewind** - Volver al inicio
- ◀️ ▶️ **Step** - Avanzar/retroceder un evento
- 🎚️ **Slider** - Saltar a cualquier momento
- ⏱️ **Speed** - 0.5x, 1x, 2x, 4x

**Qué observar:**
- ✅ Los nodos cambian de color a medida que avanza el tiempo
- ✅ El panel lateral muestra el evento actual
- ✅ Marcadores rojos/amarillos indican errores y retries
- ✅ Puedes "rebobinar" para entender exactamente qué pasó

**Casos de uso:**
- 🔍 Debugging de fallos en producción
- 📚 Onboarding de nuevos desarrolladores
- 📊 Post-mortem de incidentes
- 🎓 Demos para stakeholders

---

### Paso 6: Activar Chaos Mode 💥 (2 min)

1. En IEx, ejecuta:
```elixir
Beamflow.Chaos.ChaosMonkey.start(:moderate)
```

2. Crea más workflows:
```elixir
for i <- 10..20 do
  WorkflowSupervisor.start_workflow(
    InsuranceWorkflow,
    "chaos-#{i}",
    %{
      "applicant_name" => "Chaos Test #{i}",
      "dni" => String.pad_leading("#{i}", 8, "0"),
      "vehicle_model" => "Auto Chaos",
      "vehicle_year" => "2023",
      "vehicle_plate" => "CHAOS-#{i}"
    }
  )
end
```

**Qué observar en el dashboard:**
- ✅ Algunos workflows **fallan intencionalmente**
- ✅ El sistema **reintenta automáticamente**
- ✅ Las **compensaciones Saga** se ejecutan
- ✅ La tasa de éxito se mantiene razonable

3. Ver estadísticas de chaos:
```elixir
Beamflow.Chaos.ChaosMonkey.stats()
```

4. Detener chaos mode:
```elixir
Beamflow.Chaos.ChaosMonkey.stop()
```

---

### Paso 7: Dashboard de Analytics (1 min)

1. Navegar a **Analytics** en el menú
2. Ver el dashboard de métricas

**Qué observar:**
- ✅ **KPIs** principales (total, completados, fallidos)
- ✅ **Gráficos de tendencia** temporal
- ✅ **Tasa de éxito** en tiempo real
- ✅ **Distribución por hora** del día

**Exportar datos:**
- Click en **"Exportar CSV"** o **"Exportar JSON"**

**API REST:**
```bash
# Health check
curl http://localhost:4000/api/health

# Métricas resumidas
curl http://localhost:4000/api/analytics/summary

# Exportar datos
curl http://localhost:4000/api/analytics/export?format=json
```

---

## 🎯 Puntos Clave para Destacar

### 1. Arquitectura OTP
```
"Cada workflow es un proceso aislado. Si uno falla, 
los demás continúan sin problema."
```

### 2. Tiempo Real sin Polling
```
"El dashboard usa WebSockets nativos de Phoenix LiveView.
Las actualizaciones llegan instantáneamente."
```

### 3. Event Sourcing
```
"Todos los eventos se guardan. Por eso podemos 
'rebobinar' cualquier workflow."
```

### 4. Saga Pattern
```
"Si un paso falla después de modificar datos,
las compensaciones deshacen los cambios automáticamente."
```

### 5. Chaos Engineering
```
"Podemos inyectar fallos aleatorios para probar 
que el sistema se recupera correctamente."
```

---

## ❓ Preguntas Frecuentes

### "¿Qué pasa si el servidor se reinicia?"
Los workflows se persisten en Mnesia (base de datos distribuida de Erlang). Al reiniciar, se recuperan automáticamente.

### "¿Cuántos workflows simultáneos soporta?"
En un solo nodo, hemos probado 10,000+ workflows concurrentes. Con clustering, escala horizontalmente.

### "¿Por qué Elixir y no Node.js/Python?"
La VM de Erlang (BEAM) fue diseñada específicamente para sistemas distribuidos y tolerantes a fallos. Elixir aprovecha 40 años de ingeniería en telecomunicaciones.

### "¿Qué es el Saga Pattern?"
Es un patrón para transacciones distribuidas. Si un paso falla, se ejecutan compensaciones (rollbacks) de los pasos anteriores.

### "¿Por qué LiveView en vez de React?"
LiveView ofrece tiempo real sin escribir JavaScript, estado compartido con el backend, y SEO incluido. Ideal para dashboards internos.

---

## 📊 Resumen Técnico

| Tecnología | Uso |
|------------|-----|
| **Elixir 1.15** | Lenguaje principal |
| **Phoenix 1.7** | Framework web |
| **LiveView** | UI en tiempo real |
| **Mnesia** | Base de datos distribuida |
| **GenServer** | Procesos con estado |
| **PubSub** | Comunicación en tiempo real |
| **Tailwind CSS** | Estilos |

---

## 🔗 Siguientes Pasos

1. **Revisar código**: `lib/beamflow/engine/` - Motor de workflows
2. **Revisar tests**: `mix test` - 334 tests pasando
3. **Documentación técnica**: `docs/adr/` - Decisiones de arquitectura
4. **Experimentar**: Crear tus propios workflows

---

> **¿Preguntas?** Abre un issue en GitHub o revisa la documentación en `docs/`.
