defmodule Beamflow.Engine.SagaTest do
  @moduledoc """
  Tests para el Saga Pattern.
  """

  use ExUnit.Case, async: true

  alias Beamflow.Engine.Saga

  # ============================================================================
  # Test Steps
  # ============================================================================

  defmodule DebitAccountStep do
    @moduledoc false
    use Beamflow.Engine.Saga

    @impl true
    def execute(context, opts) do
      amount = Keyword.get(opts, :amount, 100)
      send(context[:test_pid], {:executed, :debit_account, amount})
      {:ok, Map.put(context, :debited, amount)}
    end

    @impl true
    def compensate(context, opts) do
      amount = Keyword.get(opts, :amount, 100)
      send(context[:test_pid], {:compensated, :debit_account, amount})
      {:ok, :credited_back}
    end
  end

  defmodule ReserveProductStep do
    @moduledoc false
    use Beamflow.Engine.Saga

    @impl true
    def execute(context, opts) do
      product_id = Keyword.get(opts, :product_id, "P001")
      send(context[:test_pid], {:executed, :reserve_product, product_id})
      {:ok, Map.put(context, :reserved_product, product_id)}
    end

    @impl true
    def compensate(context, opts) do
      product_id = Keyword.get(opts, :product_id, "P001")
      send(context[:test_pid], {:compensated, :reserve_product, product_id})
      {:ok, :product_released}
    end
  end

  defmodule SendConfirmationStep do
    @moduledoc false
    use Beamflow.Engine.Saga

    def execute(context, _opts) do
      if context[:fail_email] do
        send(context[:test_pid], {:executed, :send_confirmation, :failed})
        {:error, :email_service_down}
      else
        send(context[:test_pid], {:executed, :send_confirmation, :success})
        {:ok, Map.put(context, :email_sent, true)}
      end
    end

    @impl true
    def compensate(context, _opts) do
      send(context[:test_pid], {:compensated, :send_confirmation, :void})
      {:ok, :email_voided}
    end
  end

  defmodule NoCompensationStep do
    @moduledoc false
    use Beamflow.Engine.Saga

    @impl true
    def execute(context, _opts) do
      send(context[:test_pid], {:executed, :no_compensation, :ok})
      {:ok, context}
    end

    # Uses default compensate/2 from macro (no-op)
  end

  defmodule FailingCompensationStep do
    @moduledoc false
    use Beamflow.Engine.Saga

    @impl true
    def execute(context, _opts) do
      {:ok, context}
    end

    @impl true
    def compensate(_context, _opts) do
      {:error, :compensation_failed}
    end
  end

  defmodule CustomCompensationModuleStep do
    @moduledoc false
    use Beamflow.Engine.Saga, compensate_with: Beamflow.Engine.SagaTest.CompensationHandler

    @impl true
    def execute(context, _opts) do
      {:ok, context}
    end
  end

  defmodule CompensationHandler do
    @moduledoc false
    def compensate(context, _opts) do
      send(context[:test_pid], {:compensated, :custom_handler, :external})
      {:ok, :handled_externally}
    end
  end

  # ============================================================================
  # Tests
  # ============================================================================

  describe "saga_enabled?/1" do
    test "returns true for saga-enabled modules" do
      assert Saga.saga_enabled?(DebitAccountStep) == true
      assert Saga.saga_enabled?(ReserveProductStep) == true
    end

    test "returns false for regular modules" do
      assert Saga.saga_enabled?(String) == false
      assert Saga.saga_enabled?(Enum) == false
    end
  end

  describe "compensation_module/1" do
    test "returns self by default" do
      assert Saga.compensation_module(DebitAccountStep) == DebitAccountStep
    end

    test "returns custom module when specified" do
      assert Saga.compensation_module(CustomCompensationModuleStep) == Beamflow.Engine.SagaTest.CompensationHandler
    end
  end

  describe "run/3 - successful execution" do
    test "executes all steps in order" do
      context = %{test_pid: self()}

      steps = [
        {DebitAccountStep, [amount: 100]},
        {ReserveProductStep, [product_id: "SKU-123"]},
        SendConfirmationStep
      ]

      {:ok, executed} = Saga.run(steps, context)

      # Verify execution order
      assert_receive {:executed, :debit_account, 100}
      assert_receive {:executed, :reserve_product, "SKU-123"}
      assert_receive {:executed, :send_confirmation, :success}

      # Verify executed steps tracking
      assert length(executed) == 3
      assert Enum.map(executed, & &1.module) == [
        DebitAccountStep,
        ReserveProductStep,
        SendConfirmationStep
      ]
    end

    test "propagates context between steps" do
      context = %{test_pid: self()}

      steps = [
        {DebitAccountStep, [amount: 50]},
        {ReserveProductStep, [product_id: "P999"]}
      ]

      {:ok, executed} = Saga.run(steps, context)

      # Last executed step should have accumulated context
      last_step = List.last(executed)
      assert last_step.result[:debited] == 50
      assert last_step.result[:reserved_product] == "P999"
    end
  end

  describe "run/3 - compensation on failure" do
    test "compensates executed steps when a step fails" do
      context = %{test_pid: self(), fail_email: true}

      steps = [
        {DebitAccountStep, [amount: 100]},
        {ReserveProductStep, [product_id: "SKU-001"]},
        SendConfirmationStep  # This will fail
      ]

      {:error, error, executed, compensations} = Saga.run(steps, context)

      # Verify failure
      assert error == {:error, :email_service_down}

      # Verify execution order
      assert_receive {:executed, :debit_account, 100}
      assert_receive {:executed, :reserve_product, "SKU-001"}
      assert_receive {:executed, :send_confirmation, :failed}

      # Verify compensation order (LIFO)
      assert_receive {:compensated, :reserve_product, "SKU-001"}
      assert_receive {:compensated, :debit_account, 100}

      # No compensation for SendConfirmation since it failed
      refute_receive {:compensated, :send_confirmation, _}

      # Verify results
      assert length(executed) == 2  # Only successful steps
      assert length(compensations) == 2  # Both compensated
    end

    test "handles empty saga gracefully" do
      {:ok, executed} = Saga.run([], %{})
      assert executed == []
    end

    test "single step failure has no compensations" do
      context = %{test_pid: self(), fail_email: true}

      steps = [SendConfirmationStep]

      {:error, _error, executed, compensations} = Saga.run(steps, context)

      assert executed == []
      assert compensations == []
    end
  end

  describe "run/3 - options" do
    test "on_compensate callback is invoked for each compensation" do
      context = %{test_pid: self(), fail_email: true}
      test_pid = self()

      on_compensate = fn module, result ->
        send(test_pid, {:callback, module, result})
      end

      steps = [
        DebitAccountStep,
        ReserveProductStep,
        SendConfirmationStep
      ]

      Saga.run(steps, context, on_compensate: on_compensate)

      assert_receive {:callback, ReserveProductStep, {:ok, :product_released}}
      assert_receive {:callback, DebitAccountStep, {:ok, :credited_back}}
    end

    test "parallel_compensation executes compensations concurrently" do
      context = %{test_pid: self(), fail_email: true}

      steps = [
        DebitAccountStep,
        ReserveProductStep,
        SendConfirmationStep
      ]

      start_time = System.monotonic_time(:millisecond)
      Saga.run(steps, context, parallel_compensation: true)
      _duration = System.monotonic_time(:millisecond) - start_time

      # Both compensations should have run
      assert_receive {:compensated, :reserve_product, _}
      assert_receive {:compensated, :debit_account, _}
    end
  end

  describe "compensate/3 - manual compensation" do
    test "compensates list of executed steps" do
      context = %{test_pid: self()}

      executed = [
        Saga.record_execution(DebitAccountStep, [amount: 200], %{debited: 200}),
        Saga.record_execution(ReserveProductStep, [product_id: "P100"], %{reserved: true})
      ]

      results = Saga.compensate(executed, context)

      # Compensations in reverse order
      assert_receive {:compensated, :reserve_product, "P100"}
      assert_receive {:compensated, :debit_account, 200}

      assert length(results) == 2
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "continues compensation even if one fails by default" do
      context = %{test_pid: self()}

      executed = [
        Saga.record_execution(DebitAccountStep, [], %{}),
        Saga.record_execution(FailingCompensationStep, [], %{})
      ]

      results = Saga.compensate(executed, context)

      # Both attempted
      assert length(results) == 2
      # First (FailingCompensationStep) fails, second (DebitAccount) succeeds
      assert [first, second] = results
      # Order is reversed in compensation
      assert first == {:error, :compensation_failed}
      assert second == {:ok, :credited_back}
    end

    test "stop_on_compensation_failure option stops on first failure" do
      context = %{test_pid: self()}

      executed = [
        Saga.record_execution(DebitAccountStep, [], %{}),
        Saga.record_execution(FailingCompensationStep, [], %{})
      ]

      results = Saga.compensate(executed, context, stop_on_compensation_failure: true)

      # Only first (FailingCompensationStep in reverse) attempted
      assert length(results) == 1
      assert [first] = results
      assert first == {:error, :compensation_failed}
    end
  end

  describe "record_execution/3" do
    test "creates execution record with timestamp" do
      record = Saga.record_execution(DebitAccountStep, [amount: 500], %{tx_id: "TX123"})

      assert record.module == DebitAccountStep
      assert record.opts == [amount: 500]
      assert record.result == %{tx_id: "TX123"}
      assert %DateTime{} = record.executed_at
    end
  end

  describe "use macro" do
    test "defines __saga_enabled__/0" do
      assert DebitAccountStep.__saga_enabled__() == true
    end

    test "defines default compensate/2 that returns ok" do
      result = NoCompensationStep.compensate(%{}, [])
      assert result == {:ok, :no_compensation_needed}
    end

    test "defines compensation_metadata/0" do
      metadata = DebitAccountStep.compensation_metadata()

      assert metadata.compensation_module == DebitAccountStep
      assert metadata.compensation_timeout == 30_000
      assert metadata.retry_compensation == false
    end

    test "allows custom compensation options" do
      # CustomCompensationModuleStep uses compensate_with: CompensationHandler
      assert CustomCompensationModuleStep.__compensation_module__() == Beamflow.Engine.SagaTest.CompensationHandler
    end
  end

  describe "integration with regular step execute" do
    test "steps with run/2 instead of execute/2 still work" do
      defmodule RunStyleStep do
        use Beamflow.Engine.Saga

        def run(context, _opts) do
          {:ok, Map.put(context, :run_style, true)}
        end

        @impl true
        def compensate(_context, _opts) do
          {:ok, :compensated}
        end
      end

      context = %{}
      {:ok, executed} = Saga.run([RunStyleStep], context)

      assert length(executed) == 1
      assert hd(executed).result[:run_style] == true
    end
  end
end
