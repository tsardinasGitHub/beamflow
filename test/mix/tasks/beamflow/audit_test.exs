defmodule Mix.Tasks.Beamflow.AuditTest do
  @moduledoc """
  Tests para el comando mix beamflow.audit
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Beamflow.Audit

  # Helper para capturar la salida y el código de exit
  defp run_audit(args) do
    output =
      capture_io(fn ->
        try do
          Audit.run(args)
        catch
          {:exit_code, code} -> send(self(), {:exit_code, code})
        end
      end)

    exit_code =
      receive do
        {:exit_code, code} -> code
      after
        100 -> nil
      end

    {output, exit_code}
  end

  # Estos tests cargan y ejecutan el audit real
  describe "run/1" do
    @tag :slow
    test "descubre workflows en el proyecto" do
      {output, exit_code} = run_audit(["--quiet"])

      # En modo quiet no debe haber output significativo
      assert is_binary(output)
      # Debe terminar exitosamente (sin errores en los workflows)
      assert exit_code in [0, nil]
    end

    test "soporta --strict mode" do
      {output, exit_code} = run_audit(["--strict", "--quiet"])

      assert is_binary(output)
      # Con strict mode puede haber warnings que no son errores
      assert exit_code in [0, nil]
    end

    test "soporta --paranoid mode" do
      {output, exit_code} = run_audit(["--paranoid", "--quiet"])

      assert is_binary(output)
      assert exit_code in [0, nil]
    end

    test "soporta --pedantic mode" do
      {output, exit_code} = run_audit(["--pedantic", "--quiet"])

      assert is_binary(output)
      # Pedantic mode puede encontrar errores
      assert exit_code in [0, 1, nil]
    end

    test "soporta --format json" do
      {output, _exit_code} = run_audit(["--format", "json"])

      # El output debe contener JSON válido
      assert output =~ ~r/"workflows"/
      assert output =~ ~r/"summary"/
    end

    test "soporta --only-errors" do
      {output, _exit_code} = run_audit(["--only-errors"])

      assert is_binary(output)
    end

    test "muestra header en formato texto" do
      {output, _exit_code} = run_audit([])

      assert output =~ "Beamflow Workflow Audit"
      assert output =~ "Checking"
      assert output =~ "workflow"
    end

    test "muestra summary" do
      {output, _exit_code} = run_audit([])

      assert output =~ "Summary:"
    end
  end

  describe "help" do
    test "--help muestra documentación" do
      {output, exit_code} = run_audit(["--help"])

      assert output =~ "beamflow.audit"
      assert output =~ "--strict"
      assert output =~ "--paranoid"
      assert output =~ "--pedantic"
      assert exit_code in [0, nil]
    end
  end
end
