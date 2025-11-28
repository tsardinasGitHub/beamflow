# Guía de Desarrollo - Beamflow

Este documento describe las herramientas y mejores prácticas utilizadas en el desarrollo de Beamflow.

## 🛠 Herramientas de Calidad de Código

### 1. **Formateo de Código (mix format)**
Formatea automáticamente el código Elixir según el estándar.

```bash
# Formatear todo el código
mix format

# Verificar si el código está formateado
mix format --check-formatted
```

### 2. **Análisis Estático (Credo)**
Analiza el código en busca de problemas de diseño, legibilidad y mantenibilidad.

```bash
# Ejecutar análisis completo
mix credo

# Modo estricto
mix credo --strict

# Auto-corregir problemas cuando sea posible
mix credo --strict --fix-all
```

**Configuración:** `.credo.exs`

### 3. **Análisis de Tipos (Dialyzer)**
Verifica tipos y encuentra discrepancias de tipos en tiempo de compilación.

```bash
# Primera vez: construir PLT (puede tomar varios minutos)
mix dialyzer

# Ejecutar análisis
mix dialyzer
```

Los archivos PLT se guardan en `priv/plts/` y están excluidos de git.

### 4. **Análisis de Seguridad (Sobelow)**
Escanea el código en busca de vulnerabilidades de seguridad comunes en aplicaciones Phoenix.

```bash
# Análisis completo de seguridad
mix sobelow

# Con configuración personalizada
mix sobelow --config

# Solo ejecutar
mix security
```

**Configuración:** `.sobelow-conf`

### 5. **Cobertura de Tests (ExCoveralls)**
Genera reportes de cobertura de código.

```bash
# Reporte en consola
mix coveralls

# Reporte HTML (se abre en el navegador)
mix coveralls.html

# Reporte detallado
mix coveralls.detail
```

Los reportes se generan en el directorio `cover/`.

### 6. **Documentación (ExDoc)**
Genera documentación HTML del proyecto.

```bash
# Generar documentación
mix docs
```

La documentación se genera en `doc/` y se puede abrir `doc/index.html`.

## 🚀 Comandos Combinados

### Verificación de Calidad Completa
```bash
# Ejecuta todos los checks (formato, credo, dialyzer, sobelow)
mix quality
```

### Auto-corrección
```bash
# Formatea código y aplica fixes automáticos de Credo
mix quality.fix
```

### Pipeline de CI/CD
Para integración continua, ejecutar en este orden:

```bash
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix sobelow --exit
mix test
mix coveralls.html
mix dialyzer
```

## 📝 Variables de Entorno

### Configuración de Desarrollo

1. Copia el archivo de ejemplo:
```bash
cp .env.example .env
```

2. Edita `.env` con tus valores personalizados:
```bash
SECRET_KEY_BASE=tu_clave_generada_con_mix_phx_gen_secret
PORT=4000
CHAOS_MODE=false
```

3. Las variables se cargan automáticamente en desarrollo gracias a `dotenvy`.

### Generar Secret Key Base
```bash
mix phx.gen.secret
```

## 🧪 Testing

### Ejecutar Tests
```bash
# Todos los tests
mix test

# Tests con cobertura
mix coveralls

# Tests específicos
mix test test/beamflow/engine_test.exs

# Tests con patrón
mix test test/beamflow/
```

### Configuración de Test
- Los tests usan su propia base de datos Mnesia en `.mnesia/test/`
- Logger configurado en nivel `:warning` para reducir ruido
- Configuración en `config/test.exs`

## 📊 Mnesia

### Tipos de Almacenamiento

Mnesia soporta dos tipos de almacenamiento:

| Tipo | Comando | Persistencia | Uso |
|------|---------|--------------|-----|
| `ram_copies` | `iex -S mix` | ❌ Solo RAM | Desarrollo rápido |
| `disc_copies` | `iex --sname beamflow -S mix` | ✅ Disco | Producción, testing |

### ¿Por qué necesito `--sname`?

Mnesia requiere un **nodo con nombre** para persistir datos en disco. Sin nombre, el nodo es "anónimo" (`nonode@nohost`) y Mnesia solo puede usar `ram_copies`.

```bash
# ❌ Nodo anónimo - datos se pierden al cerrar
iex -S mix
# Resultado: nonode@nohost

# ✅ Nodo nombrado - datos persisten en .mnesia/
iex --sname beamflow -S mix
# Resultado: beamflow@hostname
```

### Directorios por Entorno
- **Desarrollo:** `.mnesia/dev/beamflow@hostname/`
- **Test:** `.mnesia/test/`
- **Producción:** Configurado vía `MNESIA_DIR` en `runtime.exs`

### Inicialización

```bash
# Primera vez: crear schema y tablas con persistencia
iex --sname beamflow -S mix run -e "Beamflow.Storage.MnesiaSetup.install()"

# Verificar tablas
iex --sname beamflow -S mix
iex> :mnesia.system_info(:tables)
# [:beamflow_workflows, :beamflow_events, :schema]
```

### Comandos Útiles

```elixir
# Ver tablas disponibles
:mnesia.system_info(:tables)

# Ver información de una tabla
:mnesia.table_info(:beamflow_workflows, :all)

# Contar registros
:mnesia.table_info(:beamflow_workflows, :size)

# Listar workflows
Beamflow.Storage.WorkflowStore.list_workflows()

# Estadísticas
Beamflow.Storage.WorkflowStore.count_by_status()

# Resetear tablas (¡CUIDADO! Borra datos)
Beamflow.Storage.MnesiaSetup.reset_tables()
```

### Backup y Restore

```bash
# Backup (copiar directorio .mnesia/)
cp -r .mnesia/dev/ backup_mnesia/

# Restore
cp -r backup_mnesia/ .mnesia/dev/
```

### Solución de Problemas

**Error: "table already exists with different storage type"**
```bash
# Limpiar y recrear
rm -rf .mnesia/
iex --sname beamflow -S mix run -e "Beamflow.Storage.MnesiaSetup.install()"
```

**Error: "no disc_copies"**
- Verifica que estás usando `--sname` o `--name`
- El nodo debe tener nombre para usar disc_copies

## 🔒 Seguridad

### Checklist de Seguridad
- ✅ No commitear archivos `.env`
- ✅ Usar `SECRET_KEY_BASE` único por entorno
- ✅ Ejecutar `mix sobelow` regularmente
- ✅ Revisar dependencias con `mix hex.audit`
- ✅ Mantener dependencias actualizadas

### Auditoría de Dependencias
```bash
mix hex.audit
mix deps.audit
```

## 📦 Setup Inicial de Proyecto

```bash
# 1. Clonar repositorio
git clone https://github.com/tsardinasGitHub/beamflow.git
cd beamflow

# 2. Instalar dependencias
mix deps.get

# 3. Configurar variables de entorno
cp .env.example .env
# Editar .env con tus valores

# 4. Setup de assets
mix assets.setup

# 5. Compilar assets
mix assets.build

# 6. Ejecutar tests
mix test

# 7. Iniciar servidor
mix phx.server
```

## 🎯 Mejores Prácticas

### Antes de Commit
```bash
mix quality.fix    # Auto-corrige formato y estilo
mix quality        # Verifica calidad
mix test           # Ejecuta tests
```

### Antes de Push
```bash
mix quality
mix test
mix coveralls
mix security
```

### Code Review Checklist
- [ ] Código formateado (`mix format`)
- [ ] Sin warnings de Credo (`mix credo --strict`)
- [ ] Sin issues de seguridad (`mix sobelow`)
- [ ] Tests pasando (`mix test`)
- [ ] Cobertura >80% (`mix coveralls`)
- [ ] Documentación actualizada
- [ ] CHANGELOG actualizado (si aplica)

## 🐛 Debugging

### IEx (Interactive Elixir)
```bash
# Iniciar con IEx
iex -S mix

# Con Phoenix
iex -S mix phx.server
```

### Modo Chaos
Para testing de resiliencia:
```bash
# En .env
CHAOS_MODE=true
CHAOS_KILL_PROBABILITY=0.1
```

## 📚 Recursos Adicionales

- [Guía de Credo](https://hexdocs.pm/credo/)
- [Dialyzer Manual](https://www.erlang.org/doc/man/dialyzer.html)
- [Sobelow Docs](https://hexdocs.pm/sobelow/)
- [ExCoveralls](https://hexdocs.pm/excoveralls/)
- [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)
