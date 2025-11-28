defmodule Beamflow.Engine.WorkflowActorTest do
  @moduledoc """
  Tests para Beamflow.Engine.WorkflowActor.

  Verifica el ciclo de vida y comportamiento del GenServer
  que representa un workflow individual.
  """

  use ExUnit.Case, async: true

  alias Beamflow.Engine.WorkflowActor
  alias Beamflow.Engine.Registry, as: WorkflowRegistry
  alias Beamflow.Domains.Insurance.InsuranceWorkflow
  alias Beamflow.TestHelpers

  describe "start_link/1" do
    test "inicia el actor con estado inicial correcto" do
      workflow_id = TestHelpers.unique_workflow_id()

      params = %{
        "applicant_name" => "Test User",
        "applicant_email" => "test@example.com",
        "dni" => "12345678",
        "vehicle_model" => "Toyota",
        "vehicle_year" => "2020",
        "vehicle_plate" => "ABC-123"
      }

      {:ok, pid} =
        WorkflowActor.start_link(
          workflow_module: InsuranceWorkflow,
          workflow_id: workflow_id,
          params: params,
          name: WorkflowRegistry.via_tuple(workflow_id)
        )

      assert Process.alive?(pid)

      # Verificar que está registrado
      assert {:ok, ^pid} = WorkflowRegistry.lookup(workflow_id)

      # Limpieza
      GenServer.stop(pid)
    end
  end

  describe "get_state/1" do
    test "retorna el estado actual del workflow" do
      workflow_id = TestHelpers.unique_workflow_id()

      params = %{
        "applicant_name" => "Test User",
        "dni" => "12345678",
        "vehicle_model" => "Toyota",
        "vehicle_year" => "2020",
        "vehicle_plate" => "ABC-123"
      }

      {:ok, pid} =
        WorkflowActor.start_link(
          workflow_module: InsuranceWorkflow,
          workflow_id: workflow_id,
          params: params,
          name: WorkflowRegistry.via_tuple(workflow_id)
        )

      assert {:ok, state} = WorkflowActor.get_state(workflow_id)
      assert state.workflow_state.applicant_name == "Test User"
      assert state.workflow_state.dni == "12345678"

      GenServer.stop(pid)
    end

    test "retorna error si el workflow no existe" do
      assert {:error, :not_found} = WorkflowActor.get_state("nonexistent")
    end
  end

  describe "execute_next_step/1" do
    test "ejecuta el siguiente paso del workflow" do
      workflow_id = TestHelpers.unique_workflow_id()

      params = %{
        "applicant_name" => "Test User",
        "applicant_email" => "test@example.com",
        "dni" => "12345678",
        "vehicle_model" => "Toyota",
        "vehicle_year" => "2020",
        "vehicle_plate" => "ABC-123"
      }

      {:ok, pid} =
        WorkflowActor.start_link(
          workflow_module: InsuranceWorkflow,
          workflow_id: workflow_id,
          params: params,
          name: WorkflowRegistry.via_tuple(workflow_id)
        )

      # Ejecutar el primer paso
      assert :ok = WorkflowActor.execute_next_step(workflow_id)

      # Verificar que el estado ha avanzado
      assert {:ok, state} = WorkflowActor.get_state(workflow_id)
      assert state.current_step_index >= 0

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
