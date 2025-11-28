defmodule Beamflow.Engine.CircuitBreakerTest do
  @moduledoc """
  Tests para el Circuit Breaker.
  """

  use ExUnit.Case, async: true

  alias Beamflow.Engine.CircuitBreaker

  # Setup para limpiar breakers entre tests
  setup do
    # Nombre único para cada test
    breaker_name = :"test_breaker_#{:erlang.unique_integer([:positive])}"
    {:ok, breaker_name: breaker_name}
  end

  describe "start_link/1" do
    test "starts a circuit breaker with defaults", %{breaker_name: name} do
      assert {:ok, pid} = CircuitBreaker.start_link(name: name)
      assert is_pid(pid)
    end

    test "starts with custom configuration", %{breaker_name: name} do
      opts = [
        name: name,
        failure_threshold: 3,
        success_threshold: 2,
        timeout: 1000
      ]

      assert {:ok, pid} = CircuitBreaker.start_link(opts)
      assert is_pid(pid)

      # Verificar estado inicial
      {:ok, status} = CircuitBreaker.status(name)
      assert status.state == :closed
      assert status.failures == 0
    end
  end

  describe "status/1" do
    test "returns initial closed state", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name)

      {:ok, status} = CircuitBreaker.status(name)

      assert status.state == :closed
      assert status.failures == 0
      assert status.successes == 0
      assert status.last_failure == nil
      assert status.opened_at == nil
    end

    test "returns error for non-existent breaker" do
      assert {:error, :not_found} = CircuitBreaker.status(:nonexistent_breaker)
    end
  end

  describe "call/3 - closed state" do
    test "executes function successfully", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name)

      result = CircuitBreaker.call(name, fn -> {:ok, 42} end)

      assert result == {:ok, 42}

      {:ok, status} = CircuitBreaker.status(name)
      assert status.successes == 1
      assert status.failures == 0
    end

    test "handles {:error, reason} result", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name)

      result = CircuitBreaker.call(name, fn -> {:error, :boom} end)

      assert result == {:error, :boom}

      {:ok, status} = CircuitBreaker.status(name)
      assert status.failures == 1
    end

    test "handles plain return values as success", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name)

      result = CircuitBreaker.call(name, fn -> "hello" end)

      assert result == {:ok, "hello"}

      {:ok, status} = CircuitBreaker.status(name)
      assert status.successes == 1
    end

    test "handles raised exceptions as failures", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name)

      result = CircuitBreaker.call(name, fn -> raise "explosion!" end)

      assert {:error, error} = result
      assert error.message =~ "explosion"

      {:ok, status} = CircuitBreaker.status(name)
      assert status.failures == 1
    end
  end

  describe "call/3 - state transitions" do
    test "opens circuit after failure_threshold failures", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 3)

      # 3 failures
      for _ <- 1..3 do
        CircuitBreaker.call(name, fn -> {:error, :fail} end)
      end

      {:ok, status} = CircuitBreaker.status(name)
      assert status.state == :open
      assert status.opened_at != nil
    end

    test "rejects calls when circuit is open", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 2, timeout: 60_000)

      # Open the circuit
      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.state == :open

      # Should return circuit_open
      result = CircuitBreaker.call(name, fn -> {:ok, "should not execute"} end)
      assert result == {:error, :circuit_open}
    end

    test "success resets failure counter in closed state", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 3)

      # 2 failures
      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.failures == 2

      # 1 success resets counter
      CircuitBreaker.call(name, fn -> {:ok, :success} end)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.failures == 0
      assert status.state == :closed
    end

    test "transitions to half-open after timeout", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 1, timeout: 50)

      # Open the circuit
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.state == :open

      # Wait for timeout
      Process.sleep(100)

      # Next call should try half-open
      CircuitBreaker.call(name, fn -> {:ok, :probe} end)

      {:ok, status} = CircuitBreaker.status(name)
      # Should be closed after success in half-open (success_threshold: 3 default)
      # Or half-open if not enough successes yet
      assert status.state in [:half_open, :closed]
    end

    test "closes from half-open after success_threshold successes", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(
        name: name,
        failure_threshold: 1,
        success_threshold: 2,
        timeout: 50
      )

      # Open the circuit
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      # Wait for timeout
      Process.sleep(60)

      # 2 successes should close it
      CircuitBreaker.call(name, fn -> {:ok, 1} end)
      CircuitBreaker.call(name, fn -> {:ok, 2} end)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.state == :closed
    end

    test "reopens from half-open on failure", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(
        name: name,
        failure_threshold: 1,
        timeout: 50
      )

      # Open the circuit
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      # Wait for timeout to go to half-open
      Process.sleep(60)

      # Failure in half-open should reopen
      CircuitBreaker.call(name, fn -> {:error, :fail_again} end)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.state == :open
    end
  end

  describe "allow?/1" do
    test "returns true for closed circuit", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name)

      assert CircuitBreaker.allow?(name) == true
    end

    test "returns false for open circuit", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 1, timeout: 60_000)

      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      assert CircuitBreaker.allow?(name) == false
    end

    test "returns false for non-existent breaker" do
      assert CircuitBreaker.allow?(:does_not_exist) == false
    end
  end

  describe "force_state/2" do
    test "forces circuit to open", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name)

      :ok = CircuitBreaker.force_state(name, :open)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.state == :open
    end

    test "forces circuit to closed", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name, failure_threshold: 1)

      # Open it
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      # Force closed
      :ok = CircuitBreaker.force_state(name, :closed)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.state == :closed
    end
  end

  describe "reset/1" do
    test "resets circuit to initial state", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name)

      # Some activity
      CircuitBreaker.call(name, fn -> {:ok, 1} end)
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      # Reset
      :ok = CircuitBreaker.reset(name)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.state == :closed
      assert status.failures == 0
      assert status.successes == 0
    end
  end

  describe "get_or_start/1" do
    test "starts breaker with named configuration" do
      name = :email_service

      # Clean up if exists
      CircuitBreaker.stop(name)

      {:ok, pid} = CircuitBreaker.get_or_start(name)
      assert is_pid(pid)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.state == :closed

      # Clean up
      CircuitBreaker.stop(name)
    end

    test "returns existing breaker" do
      name = :"reuse_test_#{:erlang.unique_integer([:positive])}"

      {:ok, pid1} = CircuitBreaker.start_link(name: name)
      {:ok, pid2} = CircuitBreaker.get_or_start(name)

      assert pid1 == pid2
    end
  end

  describe "report_success/1 and report_failure/2" do
    test "manually report success", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name)

      CircuitBreaker.report_success(name)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.successes == 1
    end

    test "manually report failure", %{breaker_name: name} do
      {:ok, _} = CircuitBreaker.start_link(name: name)

      CircuitBreaker.report_failure(name, :some_error)

      {:ok, status} = CircuitBreaker.status(name)
      assert status.failures == 1
    end
  end

  describe "state change callback" do
    test "invokes callback on state transition", %{breaker_name: name} do
      test_pid = self()

      callback = fn old_state, new_state ->
        send(test_pid, {:state_changed, old_state, new_state})
      end

      {:ok, _} = CircuitBreaker.start_link(
        name: name,
        failure_threshold: 1,
        on_state_change: callback
      )

      # Trigger transition to open
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      assert_receive {:state_changed, :closed, :open}, 1000
    end
  end
end
