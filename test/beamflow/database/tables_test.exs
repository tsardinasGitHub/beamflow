defmodule Beamflow.Database.TablesTest do
  @moduledoc """
  Tests para las tablas Amnesia definidas en Database.

  Valida las funciones helper dentro de cada tabla (new, update, etc.)
  y la serialización JSON.
  """

  use ExUnit.Case, async: false

  alias Beamflow.Database.Setup
  alias Beamflow.Database.{Workflow, Event, Idempotency, DeadLetterEntry}

  setup_all do
    :mnesia.start()
    Setup.init(force: true)
    :ok
  end

  setup do
    Enum.each([Workflow, Event, Idempotency, DeadLetterEntry], fn table ->
      :mnesia.clear_table(table)
    end)

    :ok
  end

  # ============================================================================
  # Workflow
  # ============================================================================

  describe "Workflow.new/1" do
    test "crea workflow con valores por defecto" do
      workflow = Workflow.new(%{
        id: "wf-new-1",
        workflow_module: MyWorkflow
      })

      assert workflow.id == "wf-new-1"
      assert workflow.workflow_module == MyWorkflow
      assert workflow.status == :pending
      assert workflow.workflow_state == %{}
      assert workflow.current_step_index == 0
      assert workflow.total_steps == 0
      assert %DateTime{} = workflow.inserted_at
      assert %DateTime{} = workflow.updated_at
    end

    test "acepta todos los campos opcionales" do
      now = DateTime.utc_now()

      workflow = Workflow.new(%{
        id: "wf-full",
        workflow_module: FullWorkflow,
        status: :running,
        workflow_state: %{data: "test"},
        current_step_index: 2,
        total_steps: 5,
        started_at: now,
        error: nil
      })

      assert workflow.status == :running
      assert workflow.workflow_state == %{data: "test"}
      assert workflow.current_step_index == 2
      assert workflow.total_steps == 5
      assert workflow.started_at == now
    end
  end

  describe "Workflow.update/2" do
    test "actualiza campos y updated_at" do
      original = Workflow.new(%{id: "wf-upd", workflow_module: Test})
      Process.sleep(10)  # Asegurar diferencia en timestamp

      updated = Workflow.update(original, %{status: :completed, current_step_index: 3})

      assert updated.status == :completed
      assert updated.current_step_index == 3
      assert DateTime.compare(updated.updated_at, original.updated_at) == :gt
    end
  end

  describe "Workflow Jason.Encoder" do
    test "serializa a JSON correctamente" do
      workflow = Workflow.new(%{
        id: "wf-json",
        workflow_module: JsonWorkflow,
        status: :completed,
        workflow_state: %{key: "value"}
      })

      json = Jason.encode!(workflow)
      decoded = Jason.decode!(json)

      assert decoded["id"] == "wf-json"
      assert decoded["workflow_module"] == "JsonWorkflow"
      assert decoded["status"] == "completed"
      assert decoded["workflow_state"] == %{"key" => "value"}
    end
  end

  # ============================================================================
  # Event
  # ============================================================================

  describe "Event.new/3" do
    test "crea evento con ID y timestamp automáticos" do
      event = Event.new("wf-123", :step_completed, %{step: "Step1", duration: 100})

      assert is_binary(event.id)
      assert String.length(event.id) == 36  # UUID v4
      assert event.workflow_id == "wf-123"
      assert event.event_type == :step_completed
      assert event.data == %{step: "Step1", duration: 100}
      assert %DateTime{} = event.timestamp
    end

    test "data es opcional" do
      event = Event.new("wf-456", :workflow_started)

      assert event.data == %{}
    end
  end

  describe "Event Jason.Encoder" do
    test "serializa a JSON correctamente" do
      event = Event.new("wf-json", :step_failed, %{error: "timeout"})

      json = Jason.encode!(event)
      decoded = Jason.decode!(json)

      assert decoded["workflow_id"] == "wf-json"
      assert decoded["event_type"] == "step_failed"
      assert decoded["data"] == %{"error" => "timeout"}
    end
  end

  # ============================================================================
  # Idempotency
  # ============================================================================

  describe "Idempotency.pending/1" do
    test "crea registro pendiente" do
      record = Idempotency.pending("wf-1:step1:0")

      assert record.key == "wf-1:step1:0"
      assert record.status == :pending
      assert %DateTime{} = record.started_at
      assert record.completed_at == nil
      assert record.result == nil
      assert record.error == nil
    end
  end

  describe "Idempotency.complete/2" do
    test "marca como completado con resultado" do
      pending = Idempotency.pending("key1")
      completed = Idempotency.complete(pending, %{output: "success"})

      assert completed.status == :completed
      assert %DateTime{} = completed.completed_at
      assert completed.result == %{output: "success"}
    end
  end

  describe "Idempotency.fail/2" do
    test "marca como fallido con error" do
      pending = Idempotency.pending("key2")
      failed = Idempotency.fail(pending, "Connection refused")

      assert failed.status == :failed
      assert %DateTime{} = failed.completed_at
      assert failed.error == "Connection refused"
    end
  end

  describe "Idempotency Jason.Encoder" do
    test "serializa a JSON correctamente" do
      record = Idempotency.pending("idem-json")
      |> Idempotency.complete(%{value: 42})

      json = Jason.encode!(record)
      decoded = Jason.decode!(json)

      assert decoded["key"] == "idem-json"
      assert decoded["status"] == "completed"
      assert decoded["result"] == %{"value" => 42}
    end
  end

  # ============================================================================
  # DeadLetterEntry
  # ============================================================================

  describe "DeadLetterEntry.new/1" do
    test "crea entrada con ID generado" do
      entry = DeadLetterEntry.new(%{
        type: :workflow_failed,
        workflow_id: "wf-failed",
        workflow_module: FailedWorkflow,
        error: "Critical error"
      })

      assert String.starts_with?(entry.id, "dlq_")
      assert entry.type == :workflow_failed
      assert entry.status == :pending
      assert entry.workflow_id == "wf-failed"
      assert entry.retry_count == 0
      assert %DateTime{} = entry.next_retry_at
      assert entry.resolution == nil
    end

    test "sanitiza datos sensibles" do
      entry = DeadLetterEntry.new(%{
        type: :workflow_failed,
        workflow_id: "wf-sens",
        workflow_module: SensitiveWorkflow,
        error: "error",
        context: %{password: "secret123", user: "john"}
      })

      assert entry.context[:user] == "john"
      refute Map.has_key?(entry.context, :password)
    end

    test "trunca strings muy largos" do
      long_string = String.duplicate("a", 2000)

      entry = DeadLetterEntry.new(%{
        type: :workflow_failed,
        workflow_id: "wf-long",
        workflow_module: LongWorkflow,
        error: "error",
        context: %{big_field: long_string}
      })

      assert String.ends_with?(entry.context.big_field, "... [truncated]")
      assert String.length(entry.context.big_field) < 1100
    end
  end

  describe "DeadLetterEntry.increment_retry/1" do
    test "incrementa contador y recalcula next_retry_at" do
      entry = DeadLetterEntry.new(%{
        type: :workflow_failed,
        workflow_id: "wf-retry",
        workflow_module: RetryWorkflow,
        error: "transient"
      })

      original_next = entry.next_retry_at

      retried = DeadLetterEntry.increment_retry(entry)

      assert retried.retry_count == 1
      assert retried.status == :retrying
      assert DateTime.compare(retried.next_retry_at, original_next) == :gt
    end
  end

  describe "DeadLetterEntry.resolve/3" do
    test "marca como resuelto" do
      entry = DeadLetterEntry.new(%{
        type: :workflow_failed,
        workflow_id: "wf-resolve",
        workflow_module: ResolveWorkflow,
        error: "fixed"
      })

      resolved = DeadLetterEntry.resolve(entry, :manual_retry, "Fixed by operator")

      assert resolved.status == :resolved
      assert resolved.resolution.type == :manual_retry
      assert resolved.resolution.notes == "Fixed by operator"
      assert %DateTime{} = resolved.resolution.resolved_at
    end

    test "marca como abandonado" do
      entry = DeadLetterEntry.new(%{
        type: :critical_failure,
        workflow_id: "wf-abandon",
        workflow_module: AbandonWorkflow,
        error: "unrecoverable"
      })

      abandoned = DeadLetterEntry.resolve(entry, :abandoned, "Cannot recover")

      assert abandoned.status == :abandoned
    end
  end

  describe "DeadLetterEntry Jason.Encoder" do
    test "serializa a JSON correctamente" do
      entry = DeadLetterEntry.new(%{
        type: :compensation_failed,
        workflow_id: "wf-dlq-json",
        workflow_module: DlqJsonWorkflow,
        failed_step: FailedStep,
        error: {:timeout, "service unavailable"}
      })

      json = Jason.encode!(entry)
      decoded = Jason.decode!(json)

      assert String.starts_with?(decoded["id"], "dlq_")
      assert decoded["type"] == "compensation_failed"
      assert decoded["workflow_id"] == "wf-dlq-json"
      assert decoded["workflow_module"] == "DlqJsonWorkflow"
      assert decoded["failed_step"] == "FailedStep"
      assert is_binary(decoded["error"])
    end
  end
end
