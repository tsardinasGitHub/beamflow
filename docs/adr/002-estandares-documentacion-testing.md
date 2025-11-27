# ADR-002: Estándares de Documentación y Testing

**Fecha**: 2025-01-15  
**Estado**: Aceptado  
**Contexto**: Proyecto de portfolio para demostrar competencias en Elixir/OTP

## Contexto

Beamflow es un proyecto diseñado para demostrar habilidades profesionales en Elixir/OTP 
ante potenciales empleadores y reclutadores técnicos. La calidad del código y su 
documentación son tan importantes como la funcionalidad misma.

## Decisión

### Documentación de Código

Se adoptan los siguientes estándares obligatorios:

#### 1. Módulos (`@moduledoc`)
Todo módulo público debe incluir:
- Propósito y responsabilidad del módulo
- Ejemplos de uso cuando aplique
- Referencias a ADRs relacionados para decisiones arquitectónicas

```elixir
@moduledoc """
Descripción concisa del propósito del módulo.

## Responsabilidades
- Punto 1
- Punto 2

## Ejemplo

    iex> Modulo.funcion()
    :resultado

Ver ADR-001 para contexto adicional.
"""
```

#### 2. Funciones Públicas (`@doc` + `@spec`)
Toda función pública debe incluir:
- `@doc` con descripción, parámetros y ejemplos
- `@spec` con tipos precisos

```elixir
@doc """
Descripción de la función.

## Parámetros
- `param1` - Descripción del parámetro

## Retorno
Descripción del valor de retorno.

## Ejemplo

    iex> funcion(valor)
    {:ok, resultado}

"""
@spec funcion(tipo_entrada()) :: {:ok, tipo_salida()} | {:error, atom()}
def funcion(param1) do
```

#### 3. Tipos Personalizados
Definir tipos para mejorar legibilidad:

```elixir
@type workflow_id :: String.t()
@type status :: :pending | :running | :completed | :failed
```

### Estándares de Testing

#### Estructura de Archivos
```
test/
├── test_helper.exs           # Configuración global
├── support/
│   └── test_helpers.ex       # Funciones auxiliares
└── beamflow/
    └── engine/
        ├── workflow_supervisor_test.exs
        ├── workflow_actor_test.exs
        └── registry_test.exs
```

#### Convenciones de Tests

1. **Descripción Clara**: Usar `describe` para agrupar y nombres descriptivos

```elixir
describe "start_workflow/2" do
  test "inicia un nuevo workflow actor exitosamente" do
  test "retorna error si el workflow ya existe" do
end
```

2. **Tags para Estados**:
   - `@tag :pending` - Tests a implementar
   - `@tag :slow` - Tests lentos (excluidos por defecto)
   - `@tag :integration` - Tests de integración

3. **Limpieza**: Siempre limpiar recursos después del test

4. **Async**: Usar `async: true` cuando sea seguro

### Herramientas de Calidad

| Herramienta | Propósito | Comando |
|-------------|-----------|---------|
| Credo | Análisis estático | `mix credo --strict` |
| Dialyzer | Verificación de tipos | `mix dialyzer` |
| ExCoveralls | Cobertura de código | `mix coveralls` |
| Sobelow | Auditoría de seguridad | `mix sobelow --config` |
| ExDoc | Documentación | `mix docs` |

### Objetivos de Cobertura

- **Mínimo aceptable**: 70%
- **Objetivo para portfolio**: 85%+
- **Prioridad**: Lógica de negocio (Engine) > Web > Infraestructura

## Consecuencias

### Positivas
- Código autodocumentado y profesional
- Facilita revisión por evaluadores técnicos
- Detecta errores temprano con Dialyzer
- Demuestra conocimiento de buenas prácticas
- CI/CD automatizado valida estándares

### Negativas
- Mayor tiempo de desarrollo inicial
- Requiere mantenimiento de documentación
- Curva de aprendizaje para Dialyzer

### Mitigaciones
- Plantillas de módulos predefinidas
- Pre-commit hooks para validación rápida
- Documentación actualizada junto con código

## Alternativas Consideradas

1. **Documentación mínima**: Rechazada - no demuestra profesionalismo
2. **Solo tests unitarios**: Rechazada - tests de integración son valiosos
3. **Sin Dialyzer**: Rechazada - tipos son diferenciador clave en Elixir

## Referencias

- [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- [Writing Documentation (Elixir School)](https://elixirschool.com/en/lessons/basics/documentation)
- [ExUnit Documentation](https://hexdocs.pm/ex_unit/ExUnit.html)
- Guía de estilo interna: `.github/copilot-instructions.md`
