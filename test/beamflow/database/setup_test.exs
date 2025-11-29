defmodule Beamflow.Database.SetupTest do
  @moduledoc """
  Tests para el módulo de setup de Amnesia.

  Valida la inicialización, status y reset de tablas.
  """

  use ExUnit.Case, async: false

  alias Beamflow.Database.Setup
  alias Beamflow.Database.{Workflow, Event, Idempotency, DeadLetterEntry}

  # Setup: Asegurar que Mnesia está corriendo antes de cada test
  setup do
    # Asegurar Mnesia corriendo
    :mnesia.start()

    on_exit(fn ->
      # Limpieza: borrar datos de prueba
      Enum.each([Workflow, Event, Idempotency, DeadLetterEntry], fn table ->
        if table in :mnesia.system_info(:tables) do
          :mnesia.clear_table(table)
        end
      end)
    end)

    :ok
  end

  describe "init/1" do
    test "crea todas las tablas cuando no existen" do
      # Reset para asegurar que no existen
      Setup.reset!()

      # Verificar status
      status = Setup.status()

      assert status.mnesia_running == true
      assert map_size(status.tables) == 4

      Enum.each([Workflow, Event, Idempotency, DeadLetterEntry], fn table ->
        assert status.tables[table].exists == true
        assert status.tables[table].count == 0
      end)
    end

    test "es idempotente - no falla si tablas ya existen" do
      # Primera inicialización
      assert :ok = Setup.init()

      # Segunda inicialización - debe ser idempotente
      assert :ok = Setup.init()

      status = Setup.status()
      assert status.mnesia_running == true
    end

    test "con force: true recrea tablas" do
      # Crear tabla con datos
      Setup.init()

      # Agregar un registro de prueba
      use Amnesia
      Amnesia.transaction do
        %Workflow{
          id: "test-wf-1",
          workflow_module: TestWorkflow,
          status: :pending,
          workflow_state: %{},
          current_step_index: 0,
          total_steps: 3,
          started_at: nil,
          completed_at: nil,
          error: nil,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        |> Workflow.write()
      end

      # Verificar que tiene datos
      status_before = Setup.status()
      assert status_before.tables[Workflow].count == 1

      # Force reset
      Setup.init(force: true)

      # Debe estar vacía
      status_after = Setup.status()
      assert status_after.tables[Workflow].count == 0
    end
  end

  describe "status/0" do
    test "retorna información completa del estado" do
      Setup.init()

      status = Setup.status()

      assert is_boolean(status.mnesia_running)
      assert is_atom(status.node)
      assert is_binary(to_string(status.directory)) or is_list(status.directory)
      assert is_map(status.tables)
    end

    test "muestra conteo correcto de registros" do
      Setup.init()

      # Insertar registros
      use Amnesia
      Amnesia.transaction do
        for i <- 1..5 do
          %Workflow{
            id: "wf-#{i}",
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
          |> Workflow.write()
        end
      end

      status = Setup.status()
      assert status.tables[Workflow].count == 5
    end
  end

  describe "tables/0" do
    test "retorna lista de módulos de tablas" do
      tables = Setup.tables()

      assert Workflow in tables
      assert Event in tables
      assert Idempotency in tables
      assert DeadLetterEntry in tables
      assert length(tables) == 4
    end
  end

  describe "reset!/1" do
    test "borra todas las tablas y las recrea" do
      Setup.init()

      # Agregar datos
      use Amnesia
      Amnesia.transaction do
        %Workflow{
          id: "to-delete",
          workflow_module: TestWorkflow,
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
        |> Workflow.write()
      end

      # Reset
      Setup.reset!()

      # Verificar tablas vacías
      status = Setup.status()
      assert status.tables[Workflow].count == 0
      assert status.tables[Workflow].exists == true
    end
  end
end
