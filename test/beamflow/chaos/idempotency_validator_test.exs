defmodule Beamflow.Chaos.IdempotencyValidatorTest do
  @moduledoc """
  Tests para IdempotencyValidator.
  """

  use ExUnit.Case, async: false

  alias Beamflow.Chaos.IdempotencyValidator

  setup do
    IdempotencyValidator.reset()
    :ok
  end

  describe "validate_fn/2" do
    test "validates idempotent function" do
      # Función que siempre retorna lo mismo
      idempotent_fn = fn -> {:ok, 42} end

      result = IdempotencyValidator.validate_fn(idempotent_fn, executions: 3)

      assert {:ok, :idempotent} = result
    end

    test "detects non-idempotent function" do
      # Función que retorna valores diferentes cada vez
      counter = :counters.new(1, [:atomics])

      non_idempotent_fn = fn ->
        :counters.add(counter, 1, 1)
        {:ok, :counters.get(counter, 1)}
      end

      result = IdempotencyValidator.validate_fn(non_idempotent_fn, executions: 3)

      assert {:ok, :not_idempotent} = result
    end

    test "handles consistent errors as idempotent" do
      # Función que siempre falla de la misma manera
      error_fn = fn -> {:error, :always_fails} end

      result = IdempotencyValidator.validate_fn(error_fn, executions: 3)

      assert {:ok, :idempotent} = result
    end

    test "respects execution limit" do
      call_count = :counters.new(1, [:atomics])

      fn_with_counter = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, :counters.get(call_count, 1)}
      end

      IdempotencyValidator.validate_fn(fn_with_counter, executions: 5)

      assert :counters.get(call_count, 1) == 5
    end
  end

  describe "validate/3" do
    test "validates simple idempotent step" do
      defmodule IdempotentStep do
        def execute(_state), do: {:ok, %{result: :fixed}}
      end

      result = IdempotencyValidator.validate(IdempotentStep, %{}, executions: 3)

      assert {:ok, :idempotent} = result
    end

    test "validates step with state transformation" do
      defmodule TransformStep do
        def execute(state) do
          {:ok, Map.put(state, :processed, true)}
        end
      end

      result = IdempotencyValidator.validate(TransformStep, %{input: "test"}, executions: 3)

      assert {:ok, :idempotent} = result
    end
  end

  describe "report/0" do
    test "returns initial report" do
      report = IdempotencyValidator.report()

      assert report.stats.total_validations == 0
      assert report.idempotency_rate == 0.0
    end

    test "tracks validations" do
      IdempotencyValidator.validate_fn(fn -> {:ok, 1} end)
      IdempotencyValidator.validate_fn(fn -> {:ok, 2} end)

      report = IdempotencyValidator.report()

      assert report.stats.total_validations == 2
    end

    test "calculates idempotency rate" do
      # Una idempotente
      IdempotencyValidator.validate_fn(fn -> {:ok, :fixed} end)

      # Una no idempotente
      counter = :counters.new(1, [:atomics])
      IdempotencyValidator.validate_fn(fn ->
        :counters.add(counter, 1, 1)
        {:ok, :counters.get(counter, 1)}
      end)

      report = IdempotencyValidator.report()

      assert report.stats.total_validations == 2
      assert report.stats.idempotent == 1
      assert report.stats.not_idempotent == 1
      assert report.idempotency_rate == 50.0
    end
  end

  describe "reset/0" do
    test "clears all stats" do
      IdempotencyValidator.validate_fn(fn -> {:ok, 1} end)
      IdempotencyValidator.validate_fn(fn -> {:ok, 2} end)

      IdempotencyValidator.reset()

      report = IdempotencyValidator.report()
      assert report.stats.total_validations == 0
    end
  end
end
