defmodule Beamflow.Engine.RegistryTest do
  @moduledoc """
  Tests para Beamflow.Engine.Registry.

  Verifica el funcionamiento del wrapper de Registry para
  localización de procesos de workflow.
  """

  use ExUnit.Case, async: true

  alias Beamflow.Engine.Registry, as: WorkflowRegistry
  alias Beamflow.TestHelpers

  describe "via_tuple/1" do
    test "genera una tupla válida para Registry" do
      workflow_id = "test_workflow_123"

      result = WorkflowRegistry.via_tuple(workflow_id)

      assert {:via, Registry, {Beamflow.Engine.Registry, "test_workflow_123"}} = result
    end
  end

  describe "lookup/1" do
    test "retorna {:ok, pid} para un proceso registrado" do
      workflow_id = TestHelpers.unique_workflow_id()

      # Simular un proceso registrado
      {:ok, pid} =
        Agent.start_link(fn -> :ok end, name: WorkflowRegistry.via_tuple(workflow_id))

      assert {:ok, ^pid} = WorkflowRegistry.lookup(workflow_id)

      Agent.stop(pid)
    end

    test "retorna {:error, :not_found} para un proceso no registrado" do
      assert {:error, :not_found} = WorkflowRegistry.lookup("nonexistent_workflow")
    end
  end

  describe "child_spec/1" do
    test "retorna child_spec válido para supervisión" do
      spec = WorkflowRegistry.child_spec([])

      assert is_map(spec)
      assert spec[:id] == Beamflow.Engine.Registry

      assert spec[:start] ==
               {Registry, :start_link, [[keys: :unique, name: Beamflow.Engine.Registry]]}
    end
  end
end
