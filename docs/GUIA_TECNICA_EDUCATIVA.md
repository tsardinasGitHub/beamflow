# 📚 Guía Técnica Educativa: BeamFlow

> **Para estudiantes que comienzan en el desarrollo de software**  
> Una inmersión profunda en los conceptos de programación funcional, sistemas distribuidos y patrones de diseño empresarial.

---

## 📖 Tabla de Contenidos

1. [Introducción: ¿Qué es BeamFlow?](#1-introducción-qué-es-beamflow)
2. [El Lenguaje: Elixir y la BEAM](#2-el-lenguaje-elixir-y-la-beam)
3. [Programación Funcional](#3-programación-funcional)
4. [OTP: El Superpoder de Erlang/Elixir](#4-otp-el-superpoder-de-erlangelixir)
5. [Patrones de Diseño Empresarial](#5-patrones-de-diseño-empresarial)
6. [Arquitectura Web con Phoenix](#6-arquitectura-web-con-phoenix)
7. [Persistencia de Datos](#7-persistencia-de-datos)
8. [Testing y Calidad](#8-testing-y-calidad)
9. [Chaos Engineering](#9-chaos-engineering)
10. [Conceptos Transversales](#10-conceptos-transversales)

---

## 1. Introducción: ¿Qué es BeamFlow?

### El Problema que Resuelve

Imagina que trabajas en una **aseguradora**. Cuando alguien solicita un seguro, deben ocurrir muchas cosas en secuencia:

1. ✅ Validar que el solicitante existe
2. ✅ Verificar su historial crediticio
3. ✅ Calcular la prima del seguro
4. ✅ Reservar la póliza
5. ✅ Enviar email de confirmación
6. ✅ Notificar al sistema de facturación

Esto es un **workflow** (flujo de trabajo). BeamFlow es un **motor de workflows** que:

- Ejecuta estos pasos en orden
- Maneja errores de forma inteligente
- Puede "deshacer" pasos si algo falla (como un Ctrl+Z)
- No pierde datos aunque el servidor se reinicie

### Analogía: La Línea de Montaje

Piensa en una **fábrica de automóviles**:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    LÍNEA DE MONTAJE DE AUTOS                        │
│                                                                     │
│  [Chasis] → [Motor] → [Ruedas] → [Pintura] → [Interior] → [✓ Auto]  │
│     ↓         ↓         ↓          ↓           ↓                    │
│  Estación  Estación  Estación   Estación    Estación                │
│     1         2         3          4           5                    │
└─────────────────────────────────────────────────────────────────────┘
```

Cada **estación** es un **step** en BeamFlow. El auto en construcción es el **estado** (state) que pasa de step en step, enriqueciéndose con cada operación.

---

## 2. El Lenguaje: Elixir y la BEAM

### ¿Qué es Elixir?

Elixir es un lenguaje de programación moderno que corre sobre la **BEAM** (Bogdan/Björn's Erlang Abstract Machine), la misma máquina virtual que usa Erlang desde 1986.

### Analogía: El Sistema Operativo Invisible

La BEAM es como un **mini sistema operativo** dentro de tu sistema operativo:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Tu Computadora (Windows/Mac/Linux)               │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                         BEAM VM                               │  │
│  │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐        │  │
│  │  │ Proc │ │ Proc │ │ Proc │ │ Proc │ │ Proc │ │ Proc │        │  │
│  │  │  1   │ │  2   │ │  3   │ │  4   │ │  5   │ │  6   │ ...    │  │
│  │  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘        │  │
│  │     │        │        │        │        │        │            │  │
│  │     └────────┴────────┴────┬───┴────────┴────────┘            │  │
│  │                            ▼                                  │  │
│  │               Scheduler (planificador)                        │  │
│  │            [Reparte tiempo entre procesos]                    │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

Estos "procesos" de la BEAM son **ultraligeros** (2KB de memoria cada uno), no como los procesos del sistema operativo. Puedes tener **millones** corriendo simultáneamente.

### Sintaxis Básica de Elixir

```elixir
# Variables (inmutables - no cambian después de asignarse)
nombre = "Juan Pérez"
edad = 30
activo = true

# Listas (colecciones ordenadas)
pasos = [:validar, :procesar, :notificar]

# Mapas (diccionarios clave-valor)
persona = %{nombre: "Ana", edad: 25, email: "ana@example.com"}

# Acceso a valores del mapa
persona.nombre      # => "Ana"
persona[:email]     # => "ana@example.com"

# Funciones (la unidad básica de trabajo)
defmodule Calculadora do
  def sumar(a, b) do
    a + b
  end
  
  def multiplicar(a, b), do: a * b  # Forma corta
end

Calculadora.sumar(2, 3)       # => 5
Calculadora.multiplicar(4, 5) # => 20
```

### El Operador Pipe (`|>`)

El pipe es como una **cinta transportadora** que pasa el resultado de una función a la siguiente:

```elixir
# Sin pipe (difícil de leer)
resultado = String.trim(String.upcase(String.replace(texto, " ", "_")))

# Con pipe (fácil de leer - ¡fluye como agua!)
resultado = 
  texto
  |> String.replace(" ", "_")
  |> String.upcase()
  |> String.trim()
```

**Analogía: Receta de Cocina**

```
Ingredientes → Lavar → Picar → Cocinar → Servir → 🍽️ Plato Listo
```

Cada paso recibe el resultado del anterior y lo transforma.

---

## 3. Programación Funcional

### ¿Qué es la Programación Funcional?

Es un paradigma donde:
1. **Las funciones son ciudadanos de primera clase** (puedes pasarlas como argumentos)
2. **Los datos son inmutables** (no cambian, se crean nuevas versiones)
3. **Las funciones son puras** (mismo input = mismo output, siempre)

### Analogía: La Fotocopiadora

En programación imperativa (Java, Python tradicional):
```
📄 Original → [Editas el original] → 📄 Original modificado
                                      (perdiste el original)
```

En programación funcional (Elixir):
```
📄 Original → [Fotocopiadora] → 📄 Copia modificada
                                 (el original sigue igual)
```

### Pattern Matching: El Superpoder de Elixir

Pattern matching es como **desempacar una caja sabiendo qué hay dentro**:

```elixir
# Desempaquetando una tupla
{:ok, resultado} = {:ok, 42}
# resultado = 42

# Desempaquetando un mapa
%{nombre: nombre, edad: edad} = %{nombre: "Pedro", edad: 30}
# nombre = "Pedro", edad = 30

# En funciones (múltiples cláusulas)
defmodule Saludo do
  def saludar(%{nombre: nombre, idioma: "es"}), do: "¡Hola, #{nombre}!"
  def saludar(%{nombre: nombre, idioma: "en"}), do: "Hello, #{nombre}!"
  def saludar(%{nombre: nombre}), do: "Hi, #{nombre}!"  # Default
end

Saludo.saludar(%{nombre: "Ana", idioma: "es"})  # => "¡Hola, Ana!"
Saludo.saludar(%{nombre: "John", idioma: "en"}) # => "Hello, John!"
```

### En BeamFlow: Pattern Matching Everywhere

```elixir
# workflow_actor.ex - Manejo de respuestas de steps
case step_module.execute(state) do
  {:ok, new_state} ->
    # El step tuvo éxito, continuar al siguiente
    handle_success(workflow, new_state)
    
  {:error, reason} ->
    # El step falló, ejecutar compensaciones
    handle_failure(workflow, reason)
end
```

### Behaviours: Contratos entre Módulos

Un **behaviour** es como un **contrato de trabajo** que dice qué funciones debe implementar un módulo:

```elixir
# Define el contrato
defmodule Beamflow.Workflows.Step do
  @callback execute(state :: map()) :: {:ok, map()} | {:error, term()}
  @callback validate(state :: map()) :: :ok | {:error, term()}
end

# Un módulo que cumple el contrato
defmodule ValidarDNI do
  @behaviour Beamflow.Workflows.Step
  
  @impl true  # Indica que implementa el callback del behaviour
  def execute(%{dni: dni} = state) do
    if valid_dni?(dni) do
      {:ok, Map.put(state, :dni_validated, true)}
    else
      {:error, :invalid_dni}
    end
  end
  
  @impl true
  def validate(%{dni: dni}) when is_binary(dni), do: :ok
  def validate(_), do: {:error, :missing_dni}
end
```

**Analogía: Franquicia de Restaurantes**

McDonald's (el behaviour) dice: "Todos nuestros locales deben tener estas funciones: `preparar_hamburguesa/1`, `servir_papas/1`, `atender_cliente/1`". Cada franquicia local implementa esas funciones a su manera, pero todas tienen las mismas operaciones disponibles.

---

## 4. OTP: El Superpoder de Erlang/Elixir

### ¿Qué es OTP?

OTP (Open Telecom Platform) es un conjunto de bibliotecas y patrones de diseño para construir sistemas:

- **Concurrentes** (muchas cosas a la vez)
- **Tolerantes a fallos** (se recuperan de errores)
- **Distribuidos** (múltiples máquinas)

### GenServer: El Trabajador con Memoria

Un GenServer es un **proceso que recuerda cosas** y responde a mensajes.

**Analogía: El Cajero del Banco**

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CAJERO (GenServer)                          │
│                                                                     │
│  Estado interno: saldo = $1000                                      │
│                                                                     │
│  📨 Cliente: "Quiero depositar $500"                                │
│  💭 Cajero: (actualiza saldo a $1500)                               │
│  📤 Cajero: "Hecho, tu saldo es $1500"                              │
│                                                                     │
│  📨 Cliente: "¿Cuánto tengo?"                                       │
│  📤 Cajero: "$1500"                                                 │
│                                                                     │
│  📨 Cliente: "Quiero retirar $2000"                                 │
│  📤 Cajero: "Error: saldo insuficiente"                             │
└─────────────────────────────────────────────────────────────────────┘
```

En código:

```elixir
defmodule CuentaBancaria do
  use GenServer
  
  # --- API Pública (lo que el cliente llama) ---
  
  def start_link(saldo_inicial) do
    GenServer.start_link(__MODULE__, saldo_inicial)
  end
  
  def depositar(pid, monto) do
    GenServer.call(pid, {:depositar, monto})
  end
  
  def consultar_saldo(pid) do
    GenServer.call(pid, :consultar_saldo)
  end
  
  # --- Callbacks (lo que el GenServer ejecuta internamente) ---
  
  @impl true
  def init(saldo_inicial) do
    {:ok, saldo_inicial}  # El estado inicial es el saldo
  end
  
  @impl true
  def handle_call({:depositar, monto}, _from, saldo) do
    nuevo_saldo = saldo + monto
    {:reply, {:ok, nuevo_saldo}, nuevo_saldo}
  end
  
  @impl true
  def handle_call(:consultar_saldo, _from, saldo) do
    {:reply, saldo, saldo}
  end
end

# Uso
{:ok, cuenta} = CuentaBancaria.start_link(1000)
CuentaBancaria.depositar(cuenta, 500)      # => {:ok, 1500}
CuentaBancaria.consultar_saldo(cuenta)     # => 1500
```

### En BeamFlow: WorkflowActor

Cada workflow en BeamFlow es un GenServer:

```elixir
# lib/beamflow/engine/workflow_actor.ex
defmodule Beamflow.Engine.WorkflowActor do
  use GenServer
  
  # Estado interno del actor
  # - workflow_id: "solicitud-123"
  # - current_step: 2
  # - status: :running
  # - workflow_state: %{dni: "12345", validated: true, ...}
end
```

### Supervisores: Los Guardaespaldas de los Procesos

Un Supervisor es un proceso que **vigila a otros procesos** y los reinicia si fallan.

**Analogía: El Jefe de Equipo**

```
┌─────────────────────────────────────────────────────────────────────┐
│                      SUPERVISOR (Jefe de Equipo)                    │
│                                                                     │
│    "Si alguno de mis trabajadores se enferma, lo reemplazo"         │
│                                                                     │
│         ┌──────────┐   ┌──────────┐   ┌──────────┐                  │
│         │ Worker 1 │   │ Worker 2 │   │ Worker 3 │                  │
│         │  (vivo)  │   │  (vivo)  │   │  (vivo)  │                  │
│         └──────────┘   └──────────┘   └──────────┘                  │
│               │              │              │                        │
│               └──────────────┼──────────────┘                        │
│                              │                                       │
│                        [Worker 2 crashea]                            │
│                              │                                       │
│                              ▼                                       │
│         ┌──────────┐   ┌──────────┐   ┌──────────┐                  │
│         │ Worker 1 │   │ Worker 2 │   │ Worker 3 │                  │
│         │  (vivo)  │   │  (nuevo) │   │  (vivo)  │                  │
│         └──────────┘   └──────────┘   └──────────┘                  │
└─────────────────────────────────────────────────────────────────────┘
```

### DynamicSupervisor: Supervisión Dinámica

A diferencia de un Supervisor normal (que tiene hijos fijos), un DynamicSupervisor puede **crear y destruir hijos en tiempo de ejecución**.

```elixir
# lib/beamflow/engine/workflow_supervisor.ex
defmodule Beamflow.Engine.WorkflowSupervisor do
  use DynamicSupervisor
  
  def start_workflow(workflow_module, workflow_id, params) do
    # Crea un nuevo WorkflowActor bajo supervisión
    DynamicSupervisor.start_child(__MODULE__, %{
      id: WorkflowActor,
      start: {WorkflowActor, :start_link, [workflow_module, workflow_id, params]}
    })
  end
end
```

**Analogía: Agencia de Empleo**

Una agencia de empleo (DynamicSupervisor) puede contratar y despedir trabajadores según la demanda, a diferencia de una empresa tradicional (Supervisor) que tiene plantilla fija.

### El Árbol de Supervisión de BeamFlow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Beamflow.Supervisor                              │
│                         │                                           │
│    ┌──────────────┬─────┴─────┬───────────────┬────────────────┐   │
│    │              │           │               │                │   │
│    ▼              ▼           ▼               ▼                ▼   │
│ PubSub      AlertSystem   DeadLetter    ChaosMonkey    WorkflowSupervisor
│                            Queue                            │      │
│                                                     ┌───────┼───────┐
│                                                     │       │       │
│                                                     ▼       ▼       ▼
│                                              Workflow  Workflow  Workflow
│                                               Actor     Actor     Actor
│                                               (wf-1)    (wf-2)    (wf-3)
└─────────────────────────────────────────────────────────────────────┘
```

### "Let It Crash": La Filosofía OTP

En lugar de intentar manejar TODOS los posibles errores con try/catch, OTP dice:

> "Deja que el proceso falle. El supervisor lo reiniciará limpio."

**Analogía: El Interruptor de la Casa**

Si un electrodoméstico causa un cortocircuito, no intentas arreglarlo mientras está conectado. Simplemente:

1. El interruptor salta (el proceso crashea)
2. Desconectas el aparato defectuoso (el supervisor limpia)
3. Subes el interruptor de nuevo (reinicio limpio)
4. Investigas qué pasó (logs)

---

## 5. Patrones de Diseño Empresarial

### 5.1 Saga Pattern

**El Problema**: Cuando una transacción involucra múltiples sistemas, ¿qué pasa si uno falla a mitad?

```
Paso 1: Cobrar tarjeta     ✅ (dinero ya salió del cliente)
Paso 2: Reservar producto  ✅ (producto reservado en inventario)
Paso 3: Enviar email       ❌ (servidor de email caído)
```

¡El cliente pagó pero nunca recibió confirmación! El producto está bloqueado pero nadie sabe por qué.

**La Solución: Saga con Compensaciones**

Cada paso define cómo "deshacerse":

```elixir
# Paso 1: Cobrar tarjeta
defmodule CobrarTarjeta do
  use Beamflow.Engine.Saga
  
  def execute(state) do
    # Cobrar
    {:ok, %{state | transaction_id: "tx_123"}}
  end
  
  def compensate(state, _opts) do
    # DESHACER: Reembolsar el cobro
    PaymentGateway.refund(state.transaction_id)
  end
end
```

**Analogía: El Escribano que Toma Notas**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    TRANSACCIÓN CON SAGA                             │
│                                                                     │
│  Escribano: 📝 "Paso 1 completado, para deshacer: reembolsar"       │
│  Escribano: 📝 "Paso 2 completado, para deshacer: liberar stock"    │
│  Escribano: ❌ "Paso 3 FALLÓ"                                       │
│                                                                     │
│  Escribano: 🔄 "Leyendo notas en reversa..."                        │
│  Escribano: ↩️  "Ejecutando: liberar stock"                         │
│  Escribano: ↩️  "Ejecutando: reembolsar"                            │
│  Escribano: ✅ "Sistema en estado consistente"                       │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.2 Circuit Breaker

**El Problema**: Si un servicio externo está caído, ¿por qué seguir llamándolo y desperdiciar recursos?

**Analogía: El Fusible Eléctrico**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CIRCUIT BREAKER                                  │
│                                                                     │
│  Estado CLOSED (fusible ok):                                        │
│    Tu App ──────────────────────────────► API Externa               │
│              "Funciona normal"                                      │
│                                                                     │
│  [5 fallos seguidos]                                                │
│                                                                     │
│  Estado OPEN (fusible quemado):                                     │
│    Tu App ────X────────────────────────► API Externa                │
│              "Ni lo intento, está caído"                            │
│              Retorno inmediato: {:error, :circuit_open}             │
│                                                                     │
│  [Pasan 30 segundos]                                                │
│                                                                     │
│  Estado HALF-OPEN (probando):                                       │
│    Tu App ──────────────────────────────► API Externa               │
│              "Dejame probar una vez..."                             │
│              Si funciona → CLOSED                                   │
│              Si falla → OPEN de nuevo                               │
└─────────────────────────────────────────────────────────────────────┘
```

En BeamFlow:

```elixir
# lib/beamflow/engine/circuit_breaker.ex
case CircuitBreaker.call(:email_service, fn -> 
  EmailAPI.send(email) 
end) do
  {:ok, response} -> 
    handle_success(response)
    
  {:error, :circuit_open} -> 
    # El circuito está abierto, usar fallback
    Logger.warn("Email service unavailable, queuing for later")
    queue_for_retry(email)
    
  {:error, reason} -> 
    handle_error(reason)
end
```

### 5.3 Retry con Backoff Exponencial

**El Problema**: ¿Cuándo reintentar un fallo y con qué frecuencia?

**Analogía: Llamar a Alguien que No Contesta**

```
Intento 1: Llamas → No contesta → Esperas 1 minuto
Intento 2: Llamas → No contesta → Esperas 2 minutos  
Intento 3: Llamas → No contesta → Esperas 4 minutos
Intento 4: Llamas → No contesta → Esperas 8 minutos
Intento 5: Llamas → No contesta → Dejas de intentar, envías email
```

El tiempo entre intentos **se duplica** (exponencial), evitando bombardear un servicio que ya está teniendo problemas.

```elixir
# lib/beamflow/engine/retry.ex
@doc """
Delay calculado: min(base * 2^attempt, max) ± jitter

Ejemplo con base=1000ms, max=30000ms:
  Intento 1: 1000ms  (1 segundo)
  Intento 2: 2000ms  (2 segundos)
  Intento 3: 4000ms  (4 segundos)
  Intento 4: 8000ms  (8 segundos)
  Intento 5: 16000ms (16 segundos)
  Intento 6: 30000ms (capped al máximo)
"""
```

**¿Qué es el Jitter?**

El jitter añade aleatoriedad al delay para evitar que muchos clientes reintenten exactamente al mismo tiempo (el "efecto manada"):

```
Sin jitter: Todos reintentan en el segundo 4.000 → Servidor colapsado
Con jitter: Reintentan entre 3.500 y 4.500 → Carga distribuida
```

### 5.4 Dead Letter Queue (DLQ)

**El Problema**: ¿Qué hacer con mensajes/workflows que fallan irrecuperablemente?

**Analogía: La Oficina de Correo**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CORREO POSTAL                                    │
│                                                                     │
│  📬 Carta normal → Entregada ✅                                     │
│                                                                     │
│  📬 Carta con dirección incorrecta:                                 │
│      Intento 1: No encontrado                                       │
│      Intento 2: No encontrado                                       │
│      Intento 3: No encontrado                                       │
│      → Enviada a "OFICINA DE CARTAS PERDIDAS" (DLQ)                │
│      → Un empleado investiga manualmente                            │
│      → Posibles acciones: reenviar, devolver, destruir              │
└─────────────────────────────────────────────────────────────────────┘
```

En BeamFlow:

```elixir
# Cuando un workflow falla después de todos los reintentos
DeadLetterQueue.enqueue(%{
  type: :compensation_failed,
  workflow_id: "wf-123",
  error: {:refund_failed, :timeout},
  context: workflow_state,
  metadata: %{attempts: 5}
})

# Un operador puede revisar y decidir
DeadLetterQueue.list_pending()  # Ver todos los fallidos
DeadLetterQueue.retry("dlq-abc")  # Reintentar uno
DeadLetterQueue.resolve("dlq-abc", :manual, "Procesado manualmente")
```

### 5.5 Idempotencia

**El Problema**: Si un proceso crashea a mitad de una operación, ¿cómo evitar duplicados al reiniciar?

**Analogía: El Recibo del Supermercado**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    COMPRA EN SUPERMERCADO                           │
│                                                                     │
│  Cajero: "Su total es $150"                                         │
│  Cliente: [Pasa tarjeta]                                            │
│  Terminal: [Se congela]                                             │
│                                                                     │
│  ❌ Sin idempotencia:                                               │
│     Cliente: "¿Pasó?" → Pasa de nuevo → Cobro doble $300            │
│                                                                     │
│  ✅ Con idempotencia:                                               │
│     Terminal guarda: "Operación #12345 = $150"                      │
│     Si pasas la tarjeta de nuevo con #12345:                        │
│     Terminal: "Ya procesé esa operación" → No cobra de nuevo        │
└─────────────────────────────────────────────────────────────────────┘
```

En BeamFlow:

```elixir
# Cada ejecución de step tiene una "idempotency key" única
idempotency_key = "workflow-123:step-2:attempt-1"

# Antes de ejecutar, verificamos
case Idempotency.check(idempotency_key) do
  {:completed, cached_result} ->
    # Ya se ejecutó antes, usar resultado guardado
    {:ok, cached_result}
    
  :not_found ->
    # Primera vez, ejecutar normalmente
    result = step.execute(state)
    Idempotency.record(idempotency_key, result)
    result
end
```

---

## 6. Arquitectura Web con Phoenix

### ¿Qué es Phoenix?

Phoenix es un framework web para Elixir, similar a Ruby on Rails o Django, pero con **superpoderes de concurrencia**.

### El Ciclo de una Petición HTTP

```
┌─────────────────────────────────────────────────────────────────────┐
│              CICLO DE VIDA DE UNA PETICIÓN                          │
│                                                                     │
│  Browser                                                            │
│     │                                                               │
│     │  GET /workflows/123                                           │
│     ▼                                                               │
│  Endpoint (punto de entrada)                                        │
│     │                                                               │
│     ▼                                                               │
│  Router (decide qué controlador/live)                               │
│     │                                                               │
│     │  live "/workflows/:id", WorkflowDetailsLive                   │
│     ▼                                                               │
│  Pipeline :browser                                                  │
│     │  - accepts ["html"]                                           │
│     │  - fetch_session                                              │
│     │  - protect_from_forgery (CSRF)                                │
│     ▼                                                               │
│  WorkflowDetailsLive.mount/3                                        │
│     │                                                               │
│     ▼                                                               │
│  WorkflowDetailsLive.render/1                                       │
│     │                                                               │
│     ▼                                                               │
│  HTML enviado al browser                                            │
└─────────────────────────────────────────────────────────────────────┘
```

### Phoenix LiveView: Interfaces Sin JavaScript

**El Problema**: Para UIs interactivas, normalmente necesitas:
- JavaScript framework (React, Vue)
- API REST/GraphQL
- Estado duplicado (servidor y cliente)
- WebSockets para tiempo real

**La Solución LiveView**: El servidor maneja TODO. El cliente solo recibe HTML.

**Analogía: Control Remoto de TV**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SIN LIVEVIEW (SPA tradicional)                   │
│                                                                     │
│  TV (Browser)          Control Remoto (JS)        Señal (Servidor)  │
│  ┌─────────┐           ┌─────────────┐            ┌──────────────┐  │
│  │         │           │ Tiene su    │            │              │  │
│  │ Pantalla│◄──────────│ propia      │◄───────────│ Envía datos  │  │
│  │         │           │ lógica      │            │ JSON         │  │
│  └─────────┘           └─────────────┘            └──────────────┘  │
│                                                                     │
│  • La TV necesita un control inteligente                            │
│  • El control toma decisiones                                       │
│  • Duplicación de lógica                                            │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    CON LIVEVIEW                                     │
│                                                                     │
│  TV (Browser)          Cable                       Servidor         │
│  ┌─────────┐           ┌─────────────┐            ┌──────────────┐  │
│  │         │           │             │            │ TODA la      │  │
│  │ Pantalla│◄──────────│ Solo envía  │◄───────────│ lógica está  │  │
│  │ "tonta" │           │ HTML        │            │ aquí         │  │
│  └─────────┘           └─────────────┘            └──────────────┘  │
│       │                                                  ▲          │
│       │  Click                                           │          │
│       └──────────────────────────────────────────────────┘          │
│         "phx-click='ver_detalle'"                                   │
│                                                                     │
│  • La pantalla solo muestra lo que el servidor envía                │
│  • Los clicks se envían al servidor                                 │
│  • El servidor actualiza y envía nuevo HTML                         │
└─────────────────────────────────────────────────────────────────────┘
```

### Ejemplo de LiveView en BeamFlow

```elixir
# lib/beamflow_web/live/workflow_explorer_live.ex
defmodule BeamflowWeb.WorkflowExplorerLive do
  use BeamflowWeb, :live_view
  
  # Se ejecuta al entrar a la página
  def mount(_params, _session, socket) do
    # Suscribirse a actualizaciones en tiempo real
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Beamflow.PubSub, "workflows")
    end
    
    # Cargar workflows iniciales
    workflows = WorkflowStore.list_workflows()
    
    {:ok, assign(socket, workflows: workflows)}
  end
  
  # Cuando un usuario hace click en "Filtrar por estado"
  def handle_event("filter", %{"status" => status}, socket) do
    filtered = WorkflowStore.list_by_status(status)
    {:noreply, assign(socket, workflows: filtered)}
  end
  
  # Cuando llega una actualización via PubSub
  def handle_info({:workflow_created, workflow}, socket) do
    # Actualizar la lista en tiempo real
    {:noreply, update(socket, :workflows, &[workflow | &1])}
  end
  
  # Render: genera el HTML
  def render(assigns) do
    ~H"""
    <div class="workflow-list">
      <h1>Workflows (<%= length(@workflows) %>)</h1>
      
      <%= for workflow <- @workflows do %>
        <div class="workflow-card" phx-click="select" phx-value-id={workflow.id}>
          <span class="status"><%= workflow.status %></span>
          <span class="id"><%= workflow.id %></span>
        </div>
      <% end %>
    </div>
    """
  end
end
```

### PubSub: Comunicación en Tiempo Real

**Analogía: El Tablón de Anuncios**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    PHOENIX PUBSUB                                   │
│                                                                     │
│  Tablón de anuncios: "workflow:wf-123"                              │
│                                                                     │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐               │
│  │ Browser 1   │   │ Browser 2   │   │ Browser 3   │               │
│  │ (Juan)      │   │ (Ana)       │   │ (Pedro)     │               │
│  │             │   │             │   │             │               │
│  │ "Estoy      │   │ "Estoy      │   │ "Estoy      │               │
│  │  suscrito"  │   │  suscrito"  │   │  suscrito"  │               │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘               │
│         │                 │                 │                       │
│         └────────────┬────┴────────────────┘                       │
│                      │                                              │
│                      ▼                                              │
│              [Workflow completa]                                    │
│                      │                                              │
│                      ▼                                              │
│         Phoenix.PubSub.broadcast(                                   │
│           "workflow:wf-123",                                        │
│           {:workflow_completed, data}                               │
│         )                                                           │
│                      │                                              │
│         ┌────────────┼────────────────────┐                        │
│         │            │                    │                        │
│         ▼            ▼                    ▼                        │
│  [Juan recibe]  [Ana recibe]       [Pedro recibe]                  │
│  "✅ Completado" "✅ Completado"   "✅ Completado"                   │
└─────────────────────────────────────────────────────────────────────┘
```

### Streams: Listas Eficientes en LiveView

Cuando tienes miles de elementos, no quieres re-renderizar toda la lista cada vez. Los **streams** permiten operaciones eficientes:

```elixir
# En mount: inicializar el stream
socket = stream(socket, :workflows, initial_workflows)

# Agregar un elemento al principio
socket = stream_insert(socket, :workflows, new_workflow, at: 0)

# Eliminar un elemento
socket = stream_delete(socket, :workflows, workflow_to_remove)

# En el template
<div id="workflows" phx-update="stream">
  <div :for={{dom_id, workflow} <- @streams.workflows} id={dom_id}>
    <%= workflow.id %>
  </div>
</div>
```

---

## 7. Persistencia de Datos

### Mnesia: La Base de Datos de Erlang

Mnesia es una base de datos distribuida que viene incluida con Erlang/OTP. No necesitas instalar nada externo.

**Analogía: Las Libretas de la Oficina**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    TIPOS DE ALMACENAMIENTO                          │
│                                                                     │
│  RAM Copies (Libreta de notas rápidas):                             │
│  ┌──────────────────┐                                               │
│  │ • Súper rápido   │   Perfecto para: Caché, datos temporales      │
│  │ • Se borra al    │   "Post-it en el monitor"                     │
│  │   apagar         │                                               │
│  └──────────────────┘                                               │
│                                                                     │
│  Disc Copies (Archivador permanente):                               │
│  ┌──────────────────┐                                               │
│  │ • Rápido (RAM)   │   Perfecto para: Datos importantes            │
│  │ • + respaldo en  │   "Libreta que fotocopias cada noche"         │
│  │   disco          │                                               │
│  └──────────────────┘                                               │
│                                                                     │
│  Disc Only (Archivo muerto):                                        │
│  ┌──────────────────┐                                               │
│  │ • Lento          │   Perfecto para: Datos masivos, históricos    │
│  │ • Mucha capacidad│   "Cajas en el almacén"                       │
│  └──────────────────┘                                               │
└─────────────────────────────────────────────────────────────────────┘
```

En BeamFlow usamos **disc_copies** para workflows y eventos:

```elixir
# lib/beamflow/storage/mnesia_setup.ex
:mnesia.create_table(:beamflow_workflows, [
  attributes: [:id, :workflow_module, :status, :workflow_state, ...],
  disc_copies: [node()],  # RAM + disco
  index: [:status]  # Índice para buscar por estado
])
```

### Event Sourcing: Guardando la Historia

En lugar de guardar solo el estado actual, guardamos **todos los eventos** que llevaron a ese estado.

**Analogía: Cuenta Bancaria**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SOLO ESTADO ACTUAL                               │
│                                                                     │
│  Cuenta #123: Saldo = $500                                          │
│                                                                     │
│  ❓ ¿Cómo llegó a $500? No sé.                                      │
│  ❓ ¿Hubo fraude? No puedo verificar.                               │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    EVENT SOURCING                                   │
│                                                                     │
│  Eventos de Cuenta #123:                                            │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ 2024-01-01 | account_opened     | {initial: $0}               │ │
│  │ 2024-01-05 | deposit_made       | {amount: $1000}             │ │
│  │ 2024-01-10 | withdrawal_made    | {amount: $200}              │ │
│  │ 2024-01-15 | fee_charged        | {amount: $50, reason: maint}│ │
│  │ 2024-01-20 | interest_credited  | {amount: $5}                │ │
│  │ 2024-01-25 | withdrawal_made    | {amount: $255}              │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  Saldo calculado: $0 + $1000 - $200 - $50 + $5 - $255 = $500 ✅     │
│                                                                     │
│  ✓ Auditoría completa                                               │
│  ✓ Puedo "viajar en el tiempo"                                      │
│  ✓ Puedo detectar anomalías                                         │
└─────────────────────────────────────────────────────────────────────┘
```

En BeamFlow, cada cambio en un workflow genera un evento:

```elixir
# Eventos que se guardan
:workflow_created
:step_started
:step_completed
:step_failed
:compensation_started
:compensation_completed
:workflow_completed
:workflow_failed
```

---

## 8. Testing y Calidad

### ExUnit: El Framework de Testing de Elixir

```elixir
# test/beamflow/engine/circuit_breaker_test.exs
defmodule Beamflow.Engine.CircuitBreakerTest do
  use ExUnit.Case, async: true  # Tests en paralelo
  
  describe "estado inicial" do
    test "el circuito comienza cerrado" do
      {:ok, cb} = CircuitBreaker.start_link(name: :test_cb)
      
      assert CircuitBreaker.status(:test_cb).state == :closed
    end
  end
  
  describe "apertura del circuito" do
    test "se abre después de N fallos consecutivos" do
      {:ok, _} = CircuitBreaker.start_link(
        name: :test_cb_open,
        failure_threshold: 3
      )
      
      # Simular 3 fallos
      for _ <- 1..3 do
        CircuitBreaker.call(:test_cb_open, fn -> {:error, :failed} end)
      end
      
      # Verificar que está abierto
      assert CircuitBreaker.status(:test_cb_open).state == :open
    end
  end
end
```

### Doctests: Documentación que se Prueba

Los ejemplos en la documentación se ejecutan como tests:

```elixir
defmodule Calculadora do
  @doc """
  Suma dos números.
  
  ## Ejemplos
  
      iex> Calculadora.sumar(2, 3)
      5
      
      iex> Calculadora.sumar(-1, 1)
      0
  """
  def sumar(a, b), do: a + b
end
```

Al ejecutar `mix test`, esos ejemplos se verifican automáticamente.

### Property-Based Testing

En lugar de probar casos específicos, defines **propiedades** que siempre deben cumplirse:

```elixir
# "Para cualquier lista de números, ordenarla y volverla a ordenar
#  da el mismo resultado"
property "sort is idempotent" do
  check all list <- list_of(integer()) do
    sorted = Enum.sort(list)
    assert Enum.sort(sorted) == sorted
  end
end
```

---

## 9. Chaos Engineering

### ¿Qué es Chaos Engineering?

Es la práctica de **inyectar fallos controlados** en un sistema para verificar que se recupera correctamente.

**Analogía: Simulacro de Incendio**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SIMULACRO DE INCENDIO                            │
│                                                                     │
│  Objetivo: Verificar que el edificio puede evacuarse                │
│                                                                     │
│  1. Disparar alarma (inyectar fallo)                                │
│  2. Observar reacción:                                              │
│     - ¿La gente sabe dónde están las salidas?                       │
│     - ¿Los extintores funcionan?                                    │
│     - ¿El generador de emergencia enciende?                         │
│  3. Documentar problemas                                            │
│  4. Mejorar procedimientos                                          │
│                                                                     │
│  ⚠️ Se hace en momento controlado, no durante horario pico          │
└─────────────────────────────────────────────────────────────────────┘
```

### ChaosMonkey en BeamFlow

```elixir
# lib/beamflow/chaos/chaos_monkey.ex

# Perfiles de intensidad
@profiles %{
  gentle: %{
    crash_probability: 0.05,      # 5% de crashes
    timeout_probability: 0.03,
    error_probability: 0.08,
    latency_probability: 0.10
  },
  moderate: %{
    crash_probability: 0.15,
    timeout_probability: 0.10,
    error_probability: 0.20,
    latency_probability: 0.25
  },
  aggressive: %{
    crash_probability: 0.30,      # 30% de crashes!
    timeout_probability: 0.20,
    error_probability: 0.35,
    latency_probability: 0.40
  }
}

# Uso
ChaosMonkey.start(:moderate)   # Activar con perfil moderado
ChaosMonkey.stats()            # Ver estadísticas
ChaosMonkey.stop()             # Detener
```

### Tipos de Fallos Inyectados

| Fallo | Descripción | Qué Prueba |
|-------|-------------|------------|
| **Crash** | Mata el proceso | Supervisión y recovery |
| **Timeout** | Bloquea la respuesta | Circuit breakers |
| **Error** | Retorna error | Retry policies |
| **Latency** | Añade delay | Timeouts configurados |
| **Compensation Fail** | Falla la compensación | DLQ y alertas |

---

## 10. Conceptos Transversales

### 10.1 Macros: Metaprogramación

Las macros permiten escribir código que **genera código**. Es como tener un asistente que escribe código repetitivo por ti.

**Analogía: Plantilla de Word**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SIN MACROS                                       │
│                                                                     │
│  Escribir 100 contratos a mano, cada uno ligeramente diferente      │
│                                                                     │
│                    CON MACROS                                       │
│                                                                     │
│  Crear plantilla: "El Sr/a {nombre} acepta pagar {monto}..."        │
│  Generar 100 contratos automáticamente con datos diferentes         │
└─────────────────────────────────────────────────────────────────────┘
```

En BeamFlow:

```elixir
# La macro "use Beamflow.Engine.Saga" genera automáticamente:
defmodule MiStep do
  use Beamflow.Engine.Saga
  
  # Esto genera automáticamente:
  # - def __saga_enabled__, do: true
  # - def __compensation_module__, do: __MODULE__
  # - def __compensation_timeout__, do: 30_000
  # - def compensate(_ctx, _opts), do: {:ok, :no_compensation_needed}
  # - ... más funciones auxiliares
end
```

### 10.2 Typespecs: Documentación de Tipos

Elixir es dinámicamente tipado, pero puedes documentar los tipos esperados:

```elixir
@type status :: :pending | :running | :completed | :failed

@spec process_workflow(String.t(), map()) :: {:ok, map()} | {:error, term()}
def process_workflow(id, params) do
  # ...
end
```

Herramientas como **Dialyzer** verifican estos tipos estáticamente.

### 10.3 Telemetría: Métricas y Observabilidad

Telemetría permite emitir eventos que luego pueden ser capturados por sistemas de monitoreo:

```elixir
# Emitir un evento
:telemetry.execute(
  [:beamflow, :workflow, :completed],
  %{duration_ms: 1500},
  %{workflow_id: "wf-123", status: :success}
)

# Capturar eventos (en otro módulo)
:telemetry.attach(
  "log-workflow-completion",
  [:beamflow, :workflow, :completed],
  fn _event, measurements, metadata, _config ->
    Logger.info("Workflow #{metadata.workflow_id} completed in #{measurements.duration_ms}ms")
  end,
  nil
)
```

### 10.4 Rate Limiting: Control de Tráfico

Limitar cuántas peticiones puede hacer un cliente en un período de tiempo.

**Analogía: Cola del Supermercado**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    RATE LIMITING                                    │
│                                                                     │
│  Regla: Máximo 60 clientes por minuto en caja                       │
│                                                                     │
│  Cliente #1-60: ✅ "Adelante"                                       │
│  Cliente #61: 🚫 "Por favor espere, vuelva en 30 segundos"          │
│                                                                     │
│  [Pasan 60 segundos - se reinicia el contador]                      │
│                                                                     │
│  Cliente #61: ✅ "Ahora sí, adelante"                               │
└─────────────────────────────────────────────────────────────────────┘
```

En BeamFlow:

```elixir
# lib/beamflow_web/plugs/rate_limiter.ex
pipeline :api_rate_limited do
  plug BeamflowWeb.Plugs.RateLimiter, 
    max_requests: 60, 
    window_ms: 60_000  # 60 requests por minuto
end
```

### 10.5 DSL (Domain Specific Language)

Un DSL es un lenguaje especializado para un dominio específico. En BeamFlow, el DSL permite definir workflows de forma declarativa:

```elixir
defmodule MiWorkflow do
  use Beamflow.Workflows.DSL
  
  workflow do
    step ValidarDatos
    step ProcesarPago
    
    branch :tipo_cliente, &(&1.premium?) do
      true  -> step EnviarGiftCard
      false -> step EnviarDescuento
    end
    
    step NotificarCliente
  end
end
```

Esto es más legible que:

```elixir
def steps do
  [ValidarDatos, ProcesarPago, ...]
end

def execute(state) do
  state
  |> ValidarDatos.execute()
  |> case do
    {:ok, s} -> ProcesarPago.execute(s)
    error -> error
  end
  |> case do
    {:ok, s} when s.premium? -> EnviarGiftCard.execute(s)
    {:ok, s} -> EnviarDescuento.execute(s)
    error -> error
  end
  # ... más y más código anidado
end
```

---

## 🎓 Resumen: Mapa Mental de Conceptos

```
                            BEAMFLOW
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
    LENGUAJE               PATRONES                  WEB
        │                      │                      │
   ┌────┴────┐           ┌─────┴─────┐          ┌────┴────┐
   │         │           │           │          │         │
 Elixir    BEAM        Saga      Circuit      Phoenix  LiveView
   │         │           │       Breaker        │         │
   ├─Pipe    ├─Procesos  │           │          ├─Router  ├─Tiempo
   ├─Pattern │ ligeros   ├─Retry     │          ├─Plugs   │ real
   │ Match   │           │           │          │         │
   └─Funcion ├─GenServer ├─DLQ       └─Backoff  └─Endpnt  └─PubSub
     pura    │           │
             ├─Supervisor└─Idempot.
             │
             └─DynamicSup
```

---

## 📚 Lecturas Recomendadas

1. **Elixir in Action** (Saša Jurić) - Para entender Elixir y OTP en profundidad
2. **Designing Data-Intensive Applications** (Martin Kleppmann) - Para patrones distribuidos
3. **Release It!** (Michael Nygard) - Para Circuit Breaker y patrones de resiliencia
4. **Programming Phoenix LiveView** (Bruce Tate) - Para LiveView

---

## 🧪 Ejercicios Sugeridos

1. **Crear un Step simple**: Implementa un step que valide un email
2. **Añadir compensación**: Agrega lógica de compensación a tu step
3. **Configurar retry**: Haz que tu step reintente 3 veces con backoff
4. **Experimentar con Chaos**: Activa ChaosMonkey y observa cómo se recupera el sistema
5. **Crear un LiveView**: Muestra una lista de workflows con actualización en tiempo real

---

> 💡 **Recuerda**: La mejor forma de aprender es **haciendo**. Clona el repositorio, ejecuta los tests, rompe cosas, y observa cómo se recuperan.

---

*Última actualización: Noviembre 2025*
