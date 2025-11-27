defmodule Beamflow.Engine.WorkflowSupervisorTest do
  @moduledoc """
  Tests para Beamflow.Engine.WorkflowSupervisor.

  Verifica el correcto funcionamiento del DynamicSupervisor
  que gestiona los procesos de workflow.
  """

  use ExUnit.Case, async: true

  alias Beamflow.Engine.WorkflowSupervisor
  alias Beamflow.TestHelpers

  describe "start_workflow/2" do
    test "inicia un nuevo workflow actor exitosamente" do
      workflow_id = TestHelpers.unique_workflow_id()
      workflow_data = %{name: "Test Workflow"}

      assert {:ok, pid} = WorkflowSupervisor.start_workflow(workflow_id, workflow_data)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Limpieza
      WorkflowSupervisor.stop_workflow(workflow_id)
    end

    test "retorna error si el workflow ya existe" do
      workflow_id = TestHelpers.unique_workflow_id()

      {:ok, _pid} = WorkflowSupervisor.start_workflow(workflow_id, %{})
      assert {:error, {:already_started, _}} = WorkflowSupervisor.start_workflow(workflow_id, %{})

      # Limpieza
      WorkflowSupervisor.stop_workflow(workflow_id)
    end
  end

  describe "stop_workflow/1" do
    test "detiene un workflow actor existente" do
      workflow_id = TestHelpers.unique_workflow_id()
      {:ok, pid} = WorkflowSupervisor.start_workflow(workflow_id, %{})

      assert :ok = WorkflowSupervisor.stop_workflow(workflow_id)

      TestHelpers.assert_eventually(fn -> not Process.alive?(pid) end)
    end

    test "retorna error si el workflow no existe" do
      assert {:error, :not_found} = WorkflowSupervisor.stop_workflow("nonexistent_workflow")
    end
  end

  describe "list_workflows/0" do
    @tag :pending
    test "lista todos los workflows activos" do
      # TODO: Implementar cuando list_workflows esté disponible
    end
  end
end
