defmodule Beamflow.Engine.WorkflowActorTest do
  @moduledoc """
  Tests para Beamflow.Engine.WorkflowActor.

  Verifica el ciclo de vida y comportamiento del GenServer
  que representa un workflow individual.
  """

  use ExUnit.Case, async: true

  alias Beamflow.Engine.WorkflowActor
  alias Beamflow.Engine.Registry, as: WorkflowRegistry
  alias Beamflow.TestHelpers

  describe "start_link/1" do
    test "inicia el actor con estado inicial correcto" do
      workflow_id = TestHelpers.unique_workflow_id()
      workflow_data = %{name: "Test", steps: []}

      {:ok, pid} =
        WorkflowActor.start_link(
          id: workflow_id,
          data: workflow_data,
          name: WorkflowRegistry.via_tuple(workflow_id)
        )

      assert Process.alive?(pid)

      # Verificar que está registrado
      assert {:ok, ^pid} = WorkflowRegistry.lookup(workflow_id)

      # Limpieza
      GenServer.stop(pid)
    end
  end

  describe "get_status/1" do
    test "retorna el estado actual del workflow" do
      workflow_id = TestHelpers.unique_workflow_id()

      {:ok, pid} =
        WorkflowActor.start_link(
          id: workflow_id,
          data: %{},
          name: WorkflowRegistry.via_tuple(workflow_id)
        )

      assert {:ok, status} = WorkflowActor.get_status(workflow_id)
      assert status == :pending

      GenServer.stop(pid)
    end

    test "retorna error si el workflow no existe" do
      assert {:error, :not_found} = WorkflowActor.get_status("nonexistent")
    end
  end

  describe "execute/1" do
    test "cambia el estado a running durante ejecución" do
      workflow_id = TestHelpers.unique_workflow_id()

      {:ok, pid} =
        WorkflowActor.start_link(
          id: workflow_id,
          data: %{steps: []},
          name: WorkflowRegistry.via_tuple(workflow_id)
        )

      assert :ok = WorkflowActor.execute(workflow_id)
      assert {:ok, status} = WorkflowActor.get_status(workflow_id)
      assert status in [:running, :completed]

      GenServer.stop(pid)
    end
  end

  describe "manejo de errores" do
    @tag :pending
    test "transiciona a :failed cuando un paso falla" do
      # TODO: Implementar cuando el manejo de errores esté completo
    end

    @tag :pending
    test "emite evento de telemetría en fallos" do
      # TODO: Implementar telemetría de fallos
    end
  end
end
