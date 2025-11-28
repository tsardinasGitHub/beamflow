# 🚀 CÓMO PROBAR EL WORKFLOW - INSTRUCCIONES RÁPIDAS

## ✅ Paso 1: IEx ya está corriendo

Si estás viendo esto, `iex -S mix` ya debería estar ejecutándose.

## 📝 Paso 2: Copia y pega estos comandos en IEx

### Configurar aliases (copiar todo junto)

```elixir
alias Beamflow.Engine.{WorkflowSupervisor, WorkflowActor}
alias Beamflow.Domains.Insurance.InsuranceWorkflow
```

### Crear una solicitud de seguro

```elixir
params = %{
  "applicant_name" => "Juan Pérez",
  "dni" => "12345678",
  "vehicle_model" => "Toyota Corolla",
  "vehicle_year" => "2020",
  "vehicle_plate" => "ABC-123"
}

{:ok, pid} = WorkflowSupervisor.start_workflow(InsuranceWorkflow, "req-001", params)
```

**Deberías ver**: `{:ok, #PID<0.xxx.0>}` y varios logs:
- `[info] Starting workflow actor: req-001`
- `[info] ValidateIdentity: Verificando DNI 12345678`
- `[info] CheckCreditScore: Consultando bureau...`
- etc.

### Esperar a que termine (5-10 segundos)

```elixir
Process.sleep(6000)
```

### Ver el resultado

```elixir
{:ok, state} = WorkflowActor.get_state("req-001")

# Estado general
IO.puts("Status: #{state.status}")
IO.puts("Steps: #{state.current_step_index}/#{state.total_steps}")

# Ver decisión final
state.workflow_state.final_decision
```

**Deberías ver algo como**:
```elixir
%{
  status: :approved,  # o :rejected
  reason: nil,
  decided_at: ~U[2025-01-15 10:30:15Z]
}
```

### Ver detalles completos

```elixir
# Score crediticio
state.workflow_state.credit_check

# Prima calculada
state.workflow_state.premium_amount

# Todo el estado
state.workflow_state |> IO.inspect(label: "Estado Completo", pretty: true)
```

---

## 🎲 Probar más solicitudes

### Solicitud 2:
```elixir
WorkflowSupervisor.start_workflow(InsuranceWorkflow, "req-002", %{
  "applicant_name" => "María González",
  "dni" => "87654321",
  "vehicle_model" => "Honda Civic",
  "vehicle_year" => "2018",
  "vehicle_plate" => "XYZ-456"
})

Process.sleep(6000)
{:ok, state} = WorkflowActor.get_state("req-002")
state.workflow_state.final_decision
```

### Solicitud 3 (vehículo muy antiguo - probable rechazo):
```elixir
WorkflowSupervisor.start_workflow(InsuranceWorkflow, "req-003", %{
  "applicant_name" => "Carlos Ruiz",
  "dni" => "11223344",
  "vehicle_model" => "Nissan Sentra",
  "vehicle_year" => "2005",
  "vehicle_plate" => "OLD-999"
})

Process.sleep(6000)
{:ok, state} = WorkflowActor.get_state("req-003")
state.workflow_state.final_decision
```

---

## 🔥 Crear 10 solicitudes simultáneas

```elixir
for i <- 1..10 do
  WorkflowSupervisor.start_workflow(
    InsuranceWorkflow,
    "req-batch-#{i}",
    %{
      "applicant_name" => "Cliente #{i}",
      "dni" => String.pad_leading("#{i * 1000}", 8, "0"),
      "vehicle_model" => "Auto #{i}",
      "vehicle_year" => "#{2015 + rem(i, 8)}",
      "vehicle_plate" => "B#{i}-#{i}#{i}#{i}"
    }
  )
end

# Esperar 8 segundos
Process.sleep(8000)

# Ver resultados de todos
for i <- 1..10 do
  {:ok, state} = WorkflowActor.get_state("req-batch-#{i}")
  decision = state.workflow_state.final_decision.status
  IO.puts("Solicitud #{i}: #{decision}")
end
```

---

## ❌ Si algo falla

### Ver workflows activos:
```elixir
DynamicSupervisor.count_children(Beamflow.Engine.WorkflowSupervisor)
```

### Detener un workflow:
```elixir
WorkflowSupervisor.stop_workflow("req-001")
```

### Ver errores de un workflow:
```elixir
{:ok, state} = WorkflowActor.get_state("req-XXX")
state.error
state.workflow_state.failure_reason
```

---

## 🎯 ¿Qué observar?

1. **Latencias variables**: Cada step tarda diferente (100-1500ms simulando APIs)
2. **Fallos aleatorios**: ~10% de workflows fallarán por "servicio no disponible"
3. **Diferentes resultados**: Algunos aprobados, otros rechazados según score/edad vehículo
4. **Concurrencia**: Múltiples workflows corriendo en paralelo sin bloquearse

---

## ✨ Siguiente paso

Una vez que veas workflows funcionando, podemos:
- Agregar persistencia en Mnesia
- Crear dashboard LiveView en tiempo real
- Implementar Chaos Mode
- Agregar tests automatizados
