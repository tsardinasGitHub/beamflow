defmodule Beamflow.TestHelpers do
  @moduledoc """
  Funciones auxiliares para tests de Beamflow.

  Provee helpers comunes para configurar fixtures, generar datos
  de prueba y simplificar assertions frecuentes.
  """

  @doc """
  Genera un ID único para workflows de test.

  ## Ejemplo

      iex> workflow_id = Beamflow.TestHelpers.unique_workflow_id()
      "workflow_abc123def456"

  """
  @spec unique_workflow_id() :: String.t()
  def unique_workflow_id do
    "workflow_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  @doc """
  Crea un workflow de prueba con valores por defecto.

  ## Opciones

  - `:id` - ID del workflow (default: generado automáticamente)
  - `:status` - Estado inicial (default: `:pending`)
  - `:data` - Datos adicionales (default: `%{}`)

  ## Ejemplo

      iex> workflow = Beamflow.TestHelpers.build_workflow(status: :running)
      %{id: "workflow_...", status: :running, data: %{}}

  """
  @spec build_workflow(keyword()) :: map()
  def build_workflow(opts \\ []) do
    %{
      id: Keyword.get(opts, :id, unique_workflow_id()),
      status: Keyword.get(opts, :status, :pending),
      data: Keyword.get(opts, :data, %{})
    }
  end

  @doc """
  Espera hasta que una condición sea verdadera o timeout.

  Útil para tests que involucran procesos asíncronos.

  ## Ejemplo

      assert_eventually(fn -> Process.alive?(pid) == false end, 1000)

  """
  @spec assert_eventually((() -> boolean()), pos_integer()) :: :ok
  def assert_eventually(condition, timeout_ms \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(condition, deadline)
  end

  defp do_assert_eventually(condition, deadline) do
    if condition.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise ExUnit.AssertionError, message: "Condition was not met within timeout"
      else
        Process.sleep(50)
        do_assert_eventually(condition, deadline)
      end
    end
  end
end
