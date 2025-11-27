# Configuración global de ExUnit para Beamflow
#
# Este archivo se ejecuta antes de cada corrida de tests.

ExUnit.start(exclude: [:pending, :slow])

# Configurar Mnesia para tests en memoria
Application.put_env(:mnesia, :dir, ~c"./test/mnesia_test")
