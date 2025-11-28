# 🧪 Guía de Pruebas - BEAMFlow

## 🚀 Opción 1: Prueba Rápida con Script (Recomendado)

El script automático ejecuta un workflow completo y muestra los resultados:

```bash
# Desde el directorio raíz del proyecto
iex -S mix

# Dentro de IEx, ejecuta:
Code.eval_file("scripts/test_insurance_workflow.exs")
```

**Salida esperada:**
```
🚗 === Prueba de Workflow de Seguro Vehicular ===

📋 Creando solicitud de seguro con:
   Solicitante: Juan Pérez García
   DNI: 12345678
   Vehículo: Toyota Corolla 2020
   Placa: ABC-123

🆔 Workflow ID: req-1234

🚀 Iniciando workflow...
✅ Workflow iniciado correctamente

⏳ Ejecutando steps (esto puede tomar 5-10 segundos)...

============================================================
📊 RESULTADO FINAL
============================================================

✓ Identidad Validada:
   DNI: 12345678
   Status: valid

✓ Verificación Crediticia:
   Score: 725
   Nivel de Riesgo: low

✓ Verificación Vehicular:
   Placa: ABC-123
   Robado: false
   Valuación: $18500

💰 Prima Calculada: $555.0

------------------------------------------------------------
🎉 SOLICITUD APROBADA

   El cliente puede proceder con la contratación del seguro.
------------------------------------------------------------
```

---

## 🔧 Opción 2: Prueba Manual Paso a Paso en IEx

### 1. Iniciar la aplicación

```bash
iex -S mix
```

### 2. Crear un workflow de seguro

```elixir
# Importar módulos necesarios
alias Beamflow.Engine.{WorkflowSupervisor, WorkflowActor}
alias Beamflow.Domains.Insurance.InsuranceWorkflow

# Parámetros de la solicitud
params = %{
  "applicant_name" => "María López",
  "dni" => "87654321",
  "vehicle_model" => "Honda Civic",
  "vehicle_year" => "2019",
  "vehicle_plate" => "XYZ-789"
}

# Iniciar el workflow
{:ok, pid} = WorkflowSupervisor.start_workflow(
  InsuranceWorkflow,
  "req-001",
  params
)

# Resultado: {:ok, #PID<0.xxx.0>}
```

### 3. Consultar el estado (espera 5-10 segundos primero)

```elixir
# Esperar a que se ejecuten los steps
Process.sleep(6000)

# Consultar estado completo
{:ok, state} = WorkflowActor.get_state("req-001")

# Ver estado general
state.status
# => :completed o :failed

# Ver paso actual
state.current_step_index
# => 4 (si completó los 4 steps)

# Ver estado del workflow
state.workflow_state
```

### 4. Inspeccionar resultados específicos

```elixir
workflow_state = state.workflow_state

# Identidad validada
workflow_state.identity_validated
# => %{dni: "87654321", status: :valid, validated_at: ~U[...]}

# Score crediticio
workflow_state.credit_check
# => %{score: 650, risk_level: :medium, checked_at: ~U[...]}

# Verificación vehicular
workflow_state.vehicle_check
# => %{plate: "XYZ-789", stolen: false, valuation: 15000, ...}

# Prima calculada
workflow_state.premium_amount
# => 585.0

# Decisión final
workflow_state.final_decision
# => %{status: :approved, reason: nil, decided_at: ~U[...]}
# o
# => %{status: :rejected, reason: "Score crediticio muy bajo", ...}
```

---

## 🎲 Opción 3: Probar Múltiples Escenarios

### Escenario 1: Solicitud con buen perfil (alta probabilidad de aprobación)

```elixir
WorkflowSupervisor.start_workflow(
  InsuranceWorkflow,
  "req-good",
  %{
    "applicant_name" => "Cliente Premium",
    "dni" => "11111111",
    "vehicle_model" => "Toyota Camry",
    "vehicle_year" => "2022",
    "vehicle_plate" => "AAA-111"
  }
)
```

### Escenario 2: Vehículo antiguo (puede ser rechazado)

```elixir
WorkflowSupervisor.start_workflow(
  InsuranceWorkflow,
  "req-old-car",
  %{
    "applicant_name" => "Cliente Vintage",
    "dni" => "22222222",
    "vehicle_model" => "Volkswagen Beetle",
    "vehicle_year" => "2005",  # Más de 15 años
    "vehicle_plate" => "OLD-123"
  }
)
```

### Escenario 3: Múltiples solicitudes simultáneas

```elixir
# Crear 5 solicitudes al mismo tiempo
for i <- 1..5 do
  WorkflowSupervisor.start_workflow(
    InsuranceWorkflow,
    "req-batch-#{i}",
    %{
      "applicant_name" => "Cliente #{i}",
      "dni" => String.pad_leading("#{i}", 8, "0"),
      "vehicle_model" => "Auto #{i}",
      "vehicle_year" => "#{2015 + i}",
      "vehicle_plate" => "B#{i}-#{i}#{i}#{i}"
    }
  )
end

# Esperar y consultar todos
Process.sleep(8000)

for i <- 1..5 do
  {:ok, state} = WorkflowActor.get_state("req-batch-#{i}")
  IO.puts("Solicitud #{i}: #{state.status} - Steps: #{state.current_step_index}/4")
end
```

---

## 🐛 Escenarios de Fallo (Para Demostrar Resiliencia)

### Fallo por servicio no disponible

Los steps tienen probabilidades de fallo simuladas. Si un workflow falla:

```elixir
{:ok, state} = WorkflowActor.get_state("req-failed")

state.status
# => :failed

state.error
# => :service_unavailable o :credit_bureau_timeout

state.workflow_state.failed_at_step
# => Beamflow.Domains.Insurance.Steps.ValidateIdentity
```

### Reintentar manualmente (futuro)

```elixir
# Por ahora, para reintentar debes crear un nuevo workflow
# En el futuro se implementará:
# WorkflowActor.retry("req-failed")
```

---

## 📊 Monitorear Workflows Activos

```elixir
# Listar procesos del supervisor
DynamicSupervisor.which_children(Beamflow.Engine.WorkflowSupervisor)

# Ver cuántos workflows están corriendo
DynamicSupervisor.count_children(Beamflow.Engine.WorkflowSupervisor)
# => %{active: 3, specs: 3, supervisors: 0, workers: 3}
```

---

## 🔍 Debugging

### Ver logs en tiempo real

Los steps imprimen logs informativos:

```
[info] Starting workflow actor: req-001 (module: Beamflow.Domains.Insurance.InsuranceWorkflow)
[info] ValidateIdentity: Verificando DNI 12345678
[info] ValidateIdentity: DNI 12345678 validado correctamente
[info] CheckCreditScore: Consultando bureau de crédito para DNI 12345678
[info] CheckCreditScore: Score 750 - Riesgo: low
[info] EvaluateVehicleRisk: Evaluando vehículo ABC-123 (2020)
[info] EvaluateVehicleRisk: Vehículo valuado en $18500, prima: $555.0
[info] ApproveRequest: Evaluando decisión final
[info] ApproveRequest: Solicitud APROBADA
```

### Inspeccionar estado interno del actor

```elixir
{:ok, state} = WorkflowActor.get_state("req-001")

# Ver todo el estado
state |> IO.inspect(label: "Estado completo", pretty: true)

# Ver solo el workflow_state
state.workflow_state |> IO.inspect(label: "Workflow State", pretty: true)
```

---

## ⚡ Tips y Trucos

### Crear alias rápidos en IEx

```elixir
# En ~/.iex.exs o al inicio de tu sesión
alias Beamflow.Engine.{WorkflowSupervisor, WorkflowActor}
alias Beamflow.Domains.Insurance.InsuranceWorkflow

# Helper para crear solicitudes rápido
defmodule TestHelpers do
  def quick_request(name, dni) do
    WorkflowSupervisor.start_workflow(
      InsuranceWorkflow,
      "req-#{dni}",
      %{
        "applicant_name" => name,
        "dni" => dni,
        "vehicle_model" => "Auto Test",
        "vehicle_year" => "2020",
        "vehicle_plate" => "TST-#{String.slice(dni, 0, 3)}"
      }
    )
  end
end

# Usar:
TestHelpers.quick_request("Juan Pérez", "12345678")
```

### Detener un workflow

```elixir
WorkflowSupervisor.stop_workflow("req-001")
```

---

## 🎯 Próximos Pasos

Una vez que compruebes que el workflow funciona:

1. **Persistencia**: Los workflows se ejecutan en memoria, agregar Mnesia para persistirlos
2. **Dashboard LiveView**: Visualizar workflows en tiempo real en el navegador
3. **Tests**: Agregar tests automatizados para cada step
4. **Chaos Mode**: Simular fallos aleatorios y ver recuperación automática

¿Dudas? Revisa los logs o inspecciona el estado del workflow.
