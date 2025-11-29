defmodule Beamflow.Database.QueryTest do
  @moduledoc """
  Tests para el módulo de queries Amnesia.

  Valida operaciones CRUD genéricas y queries específicas por tabla.
  """

  use ExUnit.Case, async: false

  alias Beamflow.Database.Setup
  alias Beamflow.Database.Query
  alias Beamflow.Database.{Workflow, Event, Idempotency, DeadLetterEntry}

  setup_all do
    # Inicializar tablas una vez para todos los tests
    :mnesia.start()
    Setup.init(force: true)
    :ok
  end

  setup do
    # Limpiar tablas antes de cada test
    Enum.each([Workflow, Event, Idempotency, DeadLetterEntry], fn table ->
      :mnesia.clear_table(table)
    end)

    :ok
  end

  # ============================================================================
  # Tests de Operaciones Genéricas
  # ============================================================================

  describe "write/1 y get/2" do
    test "escribe y lee un workflow correctamente" do
      workflow = %Workflow{
        id: "wf-test-1",
        workflow_module: MyWorkflow,
        status: :pending,
        workflow_state: %{user_id: 123},
        current_step_index: 0,
        total_steps: 3,
        started_at: nil,
        completed_at: nil,
        error: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert {:ok, ^workflow} = Query.write(workflow)
      assert {:ok, retrieved} = Query.get(Workflow, "wf-test-1")
      assert retrieved.id == "wf-test-1"
      assert retrieved.status == :pending
      assert retrieved.workflow_state == %{user_id: 123}
    end

    test "retorna error :not_found cuando no existe" do
      assert {:error, :not_found} = Query.get(Workflow, "no-existe")
    end
  end

  describe "create/1" do
    test "es alias de write" do
      workflow = %Workflow{
        id: "wf-create-test",
        workflow_module: TestWorkflow,
        status: :running,
        workflow_state: %{},
        current_step_index: 1,
        total_steps: 2,
        started_at: DateTime.utc_now(),
        completed_at: nil,
        error: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert {:ok, _} = Query.create(workflow)
      assert {:ok, _} = Query.get(Workflow, "wf-create-test")
    end
  end

  describe "update/2" do
    test "actualiza atributos de un registro" do
      workflow = %Workflow{
        id: "wf-update-test",
        workflow_module: TestWorkflow,
        status: :pending,
        workflow_state: %{step: 1},
        current_step_index: 0,
        total_steps: 3,
        started_at: nil,
        completed_at: nil,
        error: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      {:ok, _} = Query.write(workflow)

      # Actualizar
      {:ok, updated} = Query.get(Workflow, "wf-update-test")
      {:ok, _} = Query.update(updated, %{status: :running, current_step_index: 1})

      # Verificar
      {:ok, final} = Query.get(Workflow, "wf-update-test")
      assert final.status == :running
      assert final.current_step_index == 1
    end
  end

  describe "delete/2" do
    test "elimina un registro por clave" do
      workflow = %Workflow{
        id: "wf-delete-test",
        workflow_module: TestWorkflow,
        status: :completed,
        workflow_state: %{},
        current_step_index: 2,
        total_steps: 2,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        error: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      {:ok, _} = Query.write(workflow)
      assert {:ok, _} = Query.get(Workflow, "wf-delete-test")

      # Eliminar
      assert :ok = Query.delete(Workflow, "wf-delete-test")

      # Verificar que no existe
      assert {:error, :not_found} = Query.get(Workflow, "wf-delete-test")
    end
  end

  describe "list/2" do
    test "lista todos los registros de una tabla" do
      for i <- 1..3 do
        workflow = %Workflow{
          id: "wf-list-#{i}",
          workflow_module: TestWorkflow,
          status: :pending,
          workflow_state: %{},
          current_step_index: 0,
          total_steps: 1,
          started_at: nil,
          completed_at: nil,
          error: nil,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Query.write(workflow)
      end

      {:ok, workflows} = Query.list(Workflow)
      assert length(workflows) == 3
    end

    test "filtra por atributos" do
      # Crear workflows con diferentes estados
      for {status, i} <- [{:pending, 1}, {:pending, 2}, {:running, 3}, {:completed, 4}] do
        workflow = %Workflow{
          id: "wf-filter-#{i}",
          workflow_module: TestWorkflow,
          status: status,
          workflow_state: %{},
          current_step_index: 0,
          total_steps: 1,
          started_at: nil,
          completed_at: nil,
          error: nil,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Query.write(workflow)
      end

      {:ok, pending} = Query.list(Workflow, status: :pending)
      assert length(pending) == 2

      {:ok, running} = Query.list(Workflow, status: :running)
      assert length(running) == 1
    end

    test "aplica límite" do
      for i <- 1..10 do
        workflow = %Workflow{
          id: "wf-limit-#{i}",
          workflow_module: TestWorkflow,
          status: :pending,
          workflow_state: %{},
          current_step_index: 0,
          total_steps: 1,
          started_at: nil,
          completed_at: nil,
          error: nil,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Query.write(workflow)
      end

      {:ok, limited} = Query.list(Workflow, limit: 5)
      assert length(limited) == 5
    end
  end

  describe "count/2" do
    test "cuenta registros con filtros" do
      for {status, i} <- [{:pending, 1}, {:pending, 2}, {:completed, 3}] do
        workflow = %Workflow{
          id: "wf-count-#{i}",
          workflow_module: TestWorkflow,
          status: status,
          workflow_state: %{},
          current_step_index: 0,
          total_steps: 1,
          started_at: nil,
          completed_at: nil,
          error: nil,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Query.write(workflow)
      end

      assert Query.count(Workflow) == 3
      assert Query.count(Workflow, status: :pending) == 2
      assert Query.count(Workflow, status: :completed) == 1
    end
  end

  # ============================================================================
  # Tests de Queries Específicas - Workflow
  # ============================================================================

  describe "list_workflows_by_status/2" do
    test "lista workflows por estado" do
      for {status, i} <- [{:pending, 1}, {:running, 2}, {:failed, 3}] do
        workflow = %Workflow{
          id: "wf-status-#{i}",
          workflow_module: TestWorkflow,
          status: status,
          workflow_state: %{},
          current_step_index: 0,
          total_steps: 1,
          started_at: nil,
          completed_at: nil,
          error: nil,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Query.write(workflow)
      end

      {:ok, running} = Query.list_workflows_by_status(:running)
      assert length(running) == 1
      assert hd(running).status == :running
    end
  end

  describe "count_workflows_by_status/0" do
    test "retorna conteo por cada estado" do
      for {status, i} <- [{:pending, 1}, {:pending, 2}, {:running, 3}, {:completed, 4}, {:failed, 5}] do
        workflow = %Workflow{
          id: "wf-count-status-#{i}",
          workflow_module: TestWorkflow,
          status: status,
          workflow_state: %{},
          current_step_index: 0,
          total_steps: 1,
          started_at: nil,
          completed_at: nil,
          error: nil,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Query.write(workflow)
      end

      counts = Query.count_workflows_by_status()

      assert counts.pending == 2
      assert counts.running == 1
      assert counts.completed == 1
      assert counts.failed == 1
    end
  end

  # ============================================================================
  # Tests de Queries Específicas - Event
  # ============================================================================

  describe "record_event/3 y get_events_for_workflow/2" do
    test "registra y recupera eventos" do
      # Crear workflow primero
      workflow = %Workflow{
        id: "wf-events-test",
        workflow_module: TestWorkflow,
        status: :running,
        workflow_state: %{},
        current_step_index: 0,
        total_steps: 2,
        started_at: DateTime.utc_now(),
        completed_at: nil,
        error: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Query.write(workflow)

      # Registrar eventos
      {:ok, _} = Query.record_event("wf-events-test", :workflow_started, %{})
      {:ok, _} = Query.record_event("wf-events-test", :step_completed, %{step: "Step1"})
      {:ok, _} = Query.record_event("wf-events-test", :step_completed, %{step: "Step2"})

      # Recuperar
      {:ok, events} = Query.get_events_for_workflow("wf-events-test")

      assert length(events) == 3
      assert Enum.any?(events, & &1.event_type == :workflow_started)
      assert Enum.count(events, & &1.event_type == :step_completed) == 2
    end
  end

  # ============================================================================
  # Tests de Queries Específicas - Idempotency
  # ============================================================================

  describe "idempotency operations" do
    test "marca pendiente, completado y fallido" do
      key = "wf-123:step1:1"

      # Pendiente
      assert :ok = Query.mark_pending(key)
      assert {:pending, _} = Query.get_idempotency_status(key)

      # Completado
      assert :ok = Query.mark_completed(key, %{result: "success"})
      assert {:completed, %{result: "success"}} = Query.get_idempotency_status(key)
    end

    test "marca fallido correctamente" do
      key = "wf-456:step2:1"

      Query.mark_pending(key)
      Query.mark_failed(key, "timeout error")

      assert {:failed, "timeout error"} = Query.get_idempotency_status(key)
    end

    test "not_found para clave inexistente" do
      assert :not_found = Query.get_idempotency_status("no-existe")
    end

    test "list_pending_idempotency retorna solo pendientes" do
      Query.mark_pending("key1")
      Query.mark_pending("key2")
      Query.mark_completed("key3", %{})

      pending = Query.list_pending_idempotency()

      assert length(pending) == 2
      assert Enum.all?(pending, & &1.status == :pending)
    end

    test "idempotency_stats retorna conteos correctos" do
      Query.mark_pending("stat-1")
      Query.mark_completed("stat-2", %{})
      Query.mark_completed("stat-3", %{})
      Query.mark_failed("stat-4", "error")

      stats = Query.idempotency_stats()

      assert stats.pending == 1
      assert stats.completed == 2
      assert stats.failed == 1
    end
  end

  # ============================================================================
  # Tests de Queries Específicas - DeadLetterEntry
  # ============================================================================

  describe "DLQ operations" do
    test "list_dlq_pending retorna entradas pendientes" do
      entry = %DeadLetterEntry{
        id: "dlq-1",
        type: :workflow_failed,
        status: :pending,
        workflow_id: "wf-failed-1",
        workflow_module: TestWorkflow,
        failed_step: nil,
        error: "some error",
        context: %{},
        original_params: %{},
        metadata: %{},
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now(),
        retry_count: 0,
        next_retry_at: DateTime.utc_now(),
        resolution: nil
      }

      Query.write(entry)

      {:ok, pending} = Query.list_dlq_pending()

      assert length(pending) == 1
      assert hd(pending).id == "dlq-1"
    end

    test "dlq_stats retorna estadísticas" do
      for {status, i} <- [{:pending, 1}, {:pending, 2}, {:resolved, 3}] do
        entry = %DeadLetterEntry{
          id: "dlq-stat-#{i}",
          type: :workflow_failed,
          status: status,
          workflow_id: "wf-#{i}",
          workflow_module: TestWorkflow,
          failed_step: nil,
          error: "error",
          context: %{},
          original_params: %{},
          metadata: %{},
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now(),
          retry_count: 0,
          next_retry_at: nil,
          resolution: nil
        }
        Query.write(entry)
      end

      stats = Query.dlq_stats()

      assert stats.total == 3
      assert stats.by_status[:pending] == 2
      assert stats.by_status[:resolved] == 1
    end
  end

  # ============================================================================
  # Tests de Utilidades
  # ============================================================================

  describe "table_stats/0" do
    test "retorna estadísticas de todas las tablas" do
      # Agregar datos
      Query.write(%Workflow{
        id: "wf-stats",
        workflow_module: Test,
        status: :pending,
        workflow_state: %{},
        current_step_index: 0,
        total_steps: 1,
        started_at: nil,
        completed_at: nil,
        error: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

      stats = Query.table_stats()

      assert length(stats) == 4
      assert Enum.find(stats, & &1.table == Workflow).count == 1
    end
  end

  describe "data_integrity_check/0" do
    test "detecta eventos huérfanos" do
      # Crear evento sin workflow
      use Amnesia
      Amnesia.transaction do
        %Event{
          id: "orphan-event",
          workflow_id: "wf-no-existe",
          event_type: :step_completed,
          data: %{},
          timestamp: DateTime.utc_now()
        }
        |> Event.write()
      end

      check = Query.data_integrity_check()

      assert check.orphaned_events == 1
      assert check.status == :issues_found
    end

    test "status :ok cuando no hay huérfanos" do
      # Crear workflow y evento relacionado
      workflow = %Workflow{
        id: "wf-integrity",
        workflow_module: Test,
        status: :completed,
        workflow_state: %{},
        current_step_index: 1,
        total_steps: 1,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        error: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Query.write(workflow)
      Query.record_event("wf-integrity", :workflow_completed, %{})

      check = Query.data_integrity_check()

      assert check.orphaned_events == 0
      assert check.status == :ok
    end
  end
end
