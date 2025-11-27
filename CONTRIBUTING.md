# Contribuyendo a Beamflow

Gracias por tu interés en contribuir a Beamflow. Este documento proporciona guías y mejores prácticas para contribuir al proyecto.

## 🌟 Código de Conducta

Este proyecto adhiere a un código de conducta. Al participar, se espera que mantengas este código. Por favor reporta comportamiento inaceptable.

## 🚀 Cómo Contribuir

### Reportar Bugs

Antes de crear un issue, por favor:
1. Verifica que no exista un issue similar
2. Usa la plantilla de bug report
3. Incluye:
   - Descripción clara del problema
   - Pasos para reproducir
   - Comportamiento esperado vs actual
   - Versión de Elixir/Erlang
   - Sistema operativo

### Sugerir Mejoras

Las sugerencias de mejoras son bienvenidas:
1. Usa la plantilla de feature request
2. Explica claramente la necesidad
3. Proporciona ejemplos de uso
4. Considera alternativas

### Pull Requests

#### Proceso

1. **Fork el repositorio** y crea tu branch desde `main`
   ```bash
   git checkout -b feature/mi-nueva-feature
   ```

2. **Configura tu entorno**
   ```bash
   mix deps.get
   cp .env.example .env
   mix test
   ```

3. **Realiza tus cambios**
   - Sigue las guías de estilo
   - Añade tests para nueva funcionalidad
   - Actualiza documentación si es necesario

4. **Ejecuta los checks de calidad**
   ```bash
   mix quality.fix      # Auto-corrige formato
   mix quality          # Verifica calidad
   mix test             # Ejecuta tests
   mix coveralls        # Verifica cobertura
   ```

5. **Commit tus cambios**
   ```bash
   git commit -m "feat: descripción clara del cambio"
   ```
   
   Usa [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat:` Nueva funcionalidad
   - `fix:` Corrección de bug
   - `docs:` Cambios en documentación
   - `style:` Formateo, sin cambios de código
   - `refactor:` Refactorización de código
   - `test:` Añadir o modificar tests
   - `chore:` Cambios en build, herramientas, etc.

6. **Push a tu fork**
   ```bash
   git push origin feature/mi-nueva-feature
   ```

7. **Abre un Pull Request**
   - Usa una descripción clara
   - Referencia issues relacionados
   - Incluye screenshots si aplica

## 📋 Guías de Estilo

### Código Elixir

1. **Formateo:** Todo el código debe estar formateado con `mix format`
2. **Credo:** Debe pasar `mix credo --strict` sin warnings
3. **Dialyzer:** No debe introducir nuevos warnings de tipos
4. **Documentación:** Módulos y funciones públicas deben tener `@moduledoc` y `@doc`

#### Ejemplo

```elixir
defmodule Beamflow.MiModulo do
  @moduledoc """
  Descripción clara de qué hace el módulo.
  """

  @doc """
  Descripción de la función.

  ## Ejemplos

      iex> MiModulo.mi_funcion("ejemplo")
      {:ok, "resultado"}
  """
  @spec mi_funcion(String.t()) :: {:ok, String.t()} | {:error, term()}
  def mi_funcion(parametro) do
    # Implementación
  end
end
```

### Tests

1. **Cobertura:** Mantener >80% de cobertura
2. **Organización:** Estructura de tests refleja `lib/`
3. **Nombres descriptivos:** Tests deben ser auto-explicativos
4. **Doctests:** Usar para ejemplos simples

```elixir
defmodule Beamflow.MiModuloTest do
  use ExUnit.Case, async: true
  
  doctest Beamflow.MiModulo

  describe "mi_funcion/1" do
    test "retorna ok con input válido" do
      assert {:ok, resultado} = MiModulo.mi_funcion("válido")
      assert resultado == "esperado"
    end

    test "retorna error con input inválido" do
      assert {:error, _razón} = MiModulo.mi_funcion(nil)
    end
  end
end
```

### Commits

- Usa tiempo presente: "Add feature" no "Added feature"
- Primera línea: resumen conciso (<50 caracteres)
- Línea en blanco
- Descripción detallada si es necesario
- Referencia issues: `Closes #123`

### Documentación

- README.md actualizado para nuevas features
- CHANGELOG.md actualizado siguiendo [Keep a Changelog](https://keepachangelog.com/)
- Docstrings para funciones públicas
- Ejemplos en doctests cuando sea apropiado

## 🔍 Checklist de Pull Request

Antes de enviar tu PR, verifica que:

- [ ] El código está formateado (`mix format`)
- [ ] Pasa todos los checks de calidad (`mix quality`)
- [ ] Todos los tests pasan (`mix test`)
- [ ] Cobertura se mantiene o mejora (`mix coveralls`)
- [ ] No hay warnings de seguridad (`mix sobelow`)
- [ ] Documentación actualizada
- [ ] CHANGELOG.md actualizado (si aplica)
- [ ] Commits siguen Conventional Commits
- [ ] PR tiene descripción clara
- [ ] Se referencian issues relacionados

## 🏗 Estructura del Proyecto

```
beamflow/
├── lib/
│   ├── beamflow/           # Lógica de negocio
│   │   ├── engine/         # Motor de workflows
│   │   └── storage/        # Capa de persistencia (Mnesia)
│   └── beamflow_web/       # Capa web (Phoenix)
│       ├── controllers/
│       ├── live/           # LiveView
│       └── components/
├── test/
│   ├── beamflow/
│   └── beamflow_web/
├── config/                 # Configuración por entorno
├── docs/                   # Documentación
│   └── adr/                # Architecture Decision Records
└── priv/
    ├── static/
    └── gettext/
```

## 🎯 Áreas de Contribución

### Necesidades Actuales

- [ ] Tests para módulos existentes
- [ ] Mejoras en documentación
- [ ] Ejemplos de uso
- [ ] Optimizaciones de rendimiento
- [ ] Mejoras en UI/UX

### Future Features (Ver Issues)

- Integración con sistemas de mensajería externos
- Dashboard de métricas avanzado
- Soporte para workflows complejos
- API REST completa

## 🤝 Proceso de Review

1. **Automatic Checks:** GitHub Actions ejecuta tests y quality checks
2. **Code Review:** Al menos un maintainer revisará el código
3. **Feedback:** Puede haber comentarios o solicitudes de cambios
4. **Merge:** Una vez aprobado, se hace merge a `main`

## 📞 Contacto

- **Issues:** Para bugs y feature requests
- **Discussions:** Para preguntas generales
- **Email:** [Tu email o email del proyecto]

## 📚 Recursos

- [Guía de Desarrollo](docs/DEVELOPMENT.md)
- [ADRs](docs/adr/)
- [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)

## 🙏 Agradecimientos

Gracias por contribuir a Beamflow. Tu ayuda hace que este proyecto sea mejor para todos.
