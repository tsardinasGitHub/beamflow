defmodule Beamflow.Engine.DeadLetterQueueTest do
  @moduledoc """
  Tests para Dead Letter Queue.
  """

  use ExUnit.Case, async: false

  alias Beamflow.Engine.DeadLetterQueue

  setup do
    # Asegurar que DLQ está corriendo
    case Process.whereis(DeadLetterQueue) do
      nil ->
        {:ok, _} = DeadLetterQueue.start_link()
      _pid ->
        :ok
    end

    :ok
  end

  describe "enqueue/1" do
    test "creates entry with correct fields" do
      opts = %{
        type: :workflow_failed,
        workflow_id: "test-wf-#{System.unique_integer([:positive])}",
        workflow_module: TestWorkflow,
        failed_step: TestStep,
        error: :timeout,
        context: %{user_id: "U123"},
        metadata: %{attempt: 3}
      }

      assert {:ok, entry_id} = DeadLetterQueue.enqueue(opts)
      assert String.starts_with?(entry_id, "dlq_")

      {:ok, entry} = DeadLetterQueue.get(entry_id)
      assert entry.type == :workflow_failed
      assert entry.status == :pending
      assert entry.workflow_id == opts.workflow_id
      assert entry.failed_step == TestStep
      assert entry.error == :timeout
      assert entry.retry_count == 0
      assert %DateTime{} = entry.created_at
    end

    test "sanitizes sensitive data from context" do
      opts = %{
        type: :critical_failure,
        workflow_id: "test-wf-123",
        workflow_module: TestWorkflow,
        error: :boom,
        context: %{
          password: "secret123",
          card_number: "4111111111111111",
          normal_data: "visible"
        },
        metadata: %{}
      }

      {:ok, entry_id} = DeadLetterQueue.enqueue(opts)
      {:ok, entry} = DeadLetterQueue.get(entry_id)

      refute Map.has_key?(entry.context, :password)
      refute Map.has_key?(entry.context, :card_number)
      assert entry.context[:normal_data] == "visible"
    end
  end

  describe "list_pending/1" do
    test "lists pending entries" do
      workflow_id = "list-test-#{System.unique_integer([:positive])}"

      {:ok, id1} = DeadLetterQueue.enqueue(%{
        type: :workflow_failed,
        workflow_id: "#{workflow_id}-1",
        workflow_module: TestWorkflow,
        error: :fail1,
        context: %{},
        metadata: %{}
      })

      {:ok, id2} = DeadLetterQueue.enqueue(%{
        type: :compensation_failed,
        workflow_id: "#{workflow_id}-2",
        workflow_module: TestWorkflow,
        error: :fail2,
        context: %{},
        metadata: %{}
      })

      {:ok, pending} = DeadLetterQueue.list_pending()

      ids = Enum.map(pending, & &1.id)
      assert id1 in ids
      assert id2 in ids
    end

    test "filters by type" do
      workflow_id = "filter-test-#{System.unique_integer([:positive])}"

      {:ok, _} = DeadLetterQueue.enqueue(%{
        type: :critical_failure,
        workflow_id: workflow_id,
        workflow_module: TestWorkflow,
        error: :critical,
        context: %{},
        metadata: %{}
      })

      {:ok, critical} = DeadLetterQueue.list_pending(type: :critical_failure)

      assert Enum.any?(critical, & &1.workflow_id == workflow_id)
    end
  end

  describe "resolve/3" do
    test "marks entry as resolved" do
      {:ok, entry_id} = DeadLetterQueue.enqueue(%{
        type: :workflow_failed,
        workflow_id: "resolve-test",
        workflow_module: TestWorkflow,
        error: :test,
        context: %{},
        metadata: %{}
      })

      :ok = DeadLetterQueue.resolve(entry_id, :manual_resolution, "Fixed manually")

      {:ok, entry} = DeadLetterQueue.get(entry_id)
      assert entry.status == :resolved
      assert entry.resolution.type == :manual_resolution
      assert entry.resolution.notes == "Fixed manually"
    end

    test "marks entry as abandoned" do
      {:ok, entry_id} = DeadLetterQueue.enqueue(%{
        type: :workflow_failed,
        workflow_id: "abandon-test",
        workflow_module: TestWorkflow,
        error: :test,
        context: %{},
        metadata: %{}
      })

      :ok = DeadLetterQueue.resolve(entry_id, :abandoned, "Customer cancelled")

      {:ok, entry} = DeadLetterQueue.get(entry_id)
      assert entry.status == :abandoned
    end
  end

  describe "stats/0" do
    test "returns statistics" do
      stats = DeadLetterQueue.stats()

      assert is_integer(stats.total)
      assert is_map(stats.by_status)
      assert is_map(stats.by_type)
    end
  end

  describe "retry/2" do
    test "returns error for non-existent entry" do
      assert {:error, :not_found} = DeadLetterQueue.retry("dlq_nonexistent")
    end

    test "increments retry count" do
      {:ok, entry_id} = DeadLetterQueue.enqueue(%{
        type: :workflow_failed,
        workflow_id: "retry-test-#{System.unique_integer([:positive])}",
        workflow_module: NonExistentWorkflow,
        error: :test,
        context: %{},
        metadata: %{}
      })

      {:ok, original} = DeadLetterQueue.get(entry_id)
      assert original.retry_count == 0

      {:ok, :retrying} = DeadLetterQueue.retry(entry_id)

      # Esperar un poco para que el proceso de retry actualice
      Process.sleep(100)

      {:ok, updated} = DeadLetterQueue.get(entry_id)
      assert updated.retry_count == 1
    end
  end
end
