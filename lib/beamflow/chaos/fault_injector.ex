defmodule Beamflow.Chaos.FaultInjector do
  @moduledoc """
  Inyector de fallos para usar dentro de Steps.

  Este módulo proporciona funciones que los steps pueden usar para
  opt-in a chaos testing. Los fallos solo se inyectan cuando
  ChaosMonkey está activo.

  ## Uso en Steps

      defmodule MyStep do
        import Beamflow.Chaos.FaultInjector

        def execute(state) do
          # Posible crash aleatorio
          maybe_crash!(:step_execution)

          # Posible latencia
          maybe_delay(:network_call)

          # Operación real
          do_something(state)
        end
      end

  ## Decoradores

  También se pueden usar como decoradores con el macro `with_chaos`:

      with_chaos :step_execution do
        expensive_operation()
      end
  """

  require Logger

  alias Beamflow.Chaos.ChaosMonkey

  @doc """
  Posiblemente crashea el proceso actual.
  Solo tiene efecto si ChaosMonkey está activo.
  """
  @spec maybe_crash!(atom()) :: :ok
  def maybe_crash!(context \\ :unknown) do
    if ChaosMonkey.should_fail?(:crash) do
      Logger.error("💥 CHAOS CRASH in #{context}")
      raise "ChaosMonkey induced crash in #{context}"
    end

    :ok
  end

  @doc """
  Posiblemente introduce latencia.
  """
  @spec maybe_delay(atom(), Range.t()) :: :ok
  def maybe_delay(context \\ :unknown, range \\ 100..2000) do
    if ChaosMonkey.should_fail?(:latency) do
      delay = Enum.random(range)
      Logger.warning("⏱️  CHAOS DELAY #{delay}ms in #{context}")
      Process.sleep(delay)
    end

    :ok
  end

  @doc """
  Posiblemente retorna un error.
  """
  @spec maybe_error(atom()) :: :ok | {:error, atom()}
  def maybe_error(context \\ :unknown) do
    if ChaosMonkey.should_fail?(:error) do
      error = Enum.random([:chaos_error, :simulated_failure, :random_error])
      Logger.warning("❌ CHAOS ERROR #{error} in #{context}")
      {:error, error}
    else
      :ok
    end
  end

  @doc """
  Posiblemente causa un timeout.
  """
  @spec maybe_timeout(atom(), pos_integer()) :: :ok
  def maybe_timeout(context \\ :unknown, timeout_ms \\ 30_000) do
    if ChaosMonkey.should_fail?(:timeout) do
      Logger.warning("⏰ CHAOS TIMEOUT in #{context} - sleeping #{timeout_ms}ms")
      Process.sleep(timeout_ms + 1000)
    end

    :ok
  end

  @doc """
  Posiblemente falla una compensación.
  Usado internamente por el Saga.
  """
  @spec maybe_fail_compensation(atom()) :: :ok | {:error, :chaos_compensation_failed}
  def maybe_fail_compensation(context \\ :unknown) do
    # Verificar flag global primero (para inyección directa)
    global_flag = :persistent_term.get(:chaos_compensation_fail, false)

    if global_flag do
      :persistent_term.put(:chaos_compensation_fail, false)
      Logger.error("💀 CHAOS COMPENSATION FAILURE (global) in #{context}")
      {:error, :chaos_compensation_failed}
    else
      if ChaosMonkey.should_fail?(:compensation_fail) do
        Logger.error("💀 CHAOS COMPENSATION FAILURE in #{context}")
        {:error, :chaos_compensation_failed}
      else
        :ok
      end
    end
  end

  @doc """
  Wrapper que ejecuta código con posibles fallos de chaos.
  """
  @spec with_chaos(atom(), keyword(), (-> term())) :: term()
  def with_chaos(context, opts \\ [], fun) do
    fault_types = Keyword.get(opts, :faults, [:crash, :latency, :error])

    # Verificar cada tipo de fallo
    Enum.each(fault_types, fn fault_type ->
      case fault_type do
        :crash -> maybe_crash!(context)
        :latency -> maybe_delay(context)
        :error ->
          case maybe_error(context) do
            {:error, reason} -> throw({:chaos_error, reason})
            :ok -> :ok
          end
        :timeout -> maybe_timeout(context)
        _ -> :ok
      end
    end)

    # Ejecutar la función real
    fun.()
  catch
    {:chaos_error, reason} -> {:error, reason}
  end

  @doc """
  Macro para envolver código con chaos testing.

  ## Ejemplo

      defmodule MyStep do
        import Beamflow.Chaos.FaultInjector

        def execute(state) do
          with_chaos_block :my_operation do
            # Tu código aquí
          end
        end
      end
  """
  defmacro with_chaos_block(context, opts \\ [], do: block) do
    quote do
      Beamflow.Chaos.FaultInjector.with_chaos(
        unquote(context),
        unquote(opts),
        fn -> unquote(block) end
      )
    end
  end

  @doc """
  Verifica si chaos mode está activo.
  Útil para logging condicional.
  """
  @spec chaos_active?() :: boolean()
  def chaos_active? do
    ChaosMonkey.enabled?()
  end
end
