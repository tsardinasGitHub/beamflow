# AGENTS.md (Resumen para agentes)

## Estilo y Sintaxis
- Elixir idiomático: funciones pequeñas, puras y composables.  
- Variables/funciones/átomos: `snake_case`.  
- Módulos: `PascalCase`.  
- Constantes: `SCREAMING_SNAKE_CASE`.  
- Indentación: 2 espacios.  
- Máx. 98 caracteres por línea.  
- Aliases ordenados alfabéticamente.  
- Usar `|>` para transformaciones.  
- Pattern matching antes que if/else.  
- Guards después del pattern matching.  
- Cláusulas homónimas agrupadas y ordenadas (específico → general).  

## Documentación
- SIEMPRE documentar:  
  - `@moduledoc` en módulos.  
  - `@doc` en funciones públicas.  
  - `@spec` en funciones públicas.  
- Doctests prácticos cuando aplique.  

## Manejo de Errores
- Operaciones fallibles: `{:ok, result}` o `{:error, reason}`.  
- Funciones con excepciones → terminan en `!`.  
- Prefiere `with` o `case` sobre `try/rescue`.  

## Phoenix / LiveView / Tailwind
- Seguir convenciones de Phoenix para routers, controllers, contexts y views.  
- LiveView para UI en tiempo real.  
- Tailwind para estilos responsivos y consistentes.  
- Mantener vistas DRY con helpers/componentes.  

## Ecto / Base de Datos
- Validaciones con changesets.  
- Transacciones con `Repo.transaction`.  
- `Repo.preload` para evitar N+1 queries.  
- Índices en la BD para performance.  
- `Repo.insert_all` para bulk inserts.  

## OTP y Concurrencia
- `GenServer` para procesos con estado.  
- `Task` para jobs simples y aislados.  
- Supervisores para robustez.  
- Evitar procesos innecesarios.  

## Testing
- Framework: ExUnit.  
- Generación de datos: ExMachina.  
- Tests reflejan estructura de `lib/`.  

## Seguridad
- Autenticación/autorización con Guardian o Pow.  
- Validación estricta de params en controladores.  
- Sobelow para auditoría.  
- Proteger contra XSS, CSRF, SQL injection.  

## Rendimiento
- Evitar procesos innecesarios.  
- ETS o Redis para caching.  
- Optimizar queries con joins y select.  
- Indexar BD.  

# Reglas Estrictas para Bloques Monádicos (Error.m)
## Sintaxis Correcta de Error.m
La sintaxis correcta utiliza `Error.m do` directamente, sin notaciones intermedias como `m:` ni asignaciones previas con `=`. Esta forma permite una composición monádica limpia donde cada operación fluye naturalmente hacia la siguiente.
## Reglas del Bloque Monádico
- **Sintaxis directa**: Usa `Error.m do` sin `m:` ni asignación intermedia
- **Operaciones monádicas**: Cada expresión con `<-` debe retornar `{:ok, valor}` o `{:error, razón}`
- **Bind monádico**: El operador `<-` extrae automáticamente valores del contexto monádico
- **Prohibido**: No uses asignación directa `=` dentro de bloques `do` - rompe la cadena monádica
- **Logging inline**: Cuando todas las operaciones son monádicas, puedes incluir logging dentro del bloque:
  - **Valores intermedios**: Usa `|> IO.inspect(label: "...")` - pasa el valor a través
  - **Logs informativos**: Usa `Logger.info("...") |> Error.return()` - convierte `:ok` a contexto monádico
- **Logging externo**: Ideal para logs iniciales o condicionales basados en el resultado final
- **Última expresión**: No requiere `<-`, se retorna directamente. Usa `Error.return()` o `Error.fail()`
- **Funciones auxiliares**: Deben retornar `{:ok, _}` o usar `Error.return()`/`Error.fail()`
- **Corte automático**: Cualquier `{:error, _}` detiene automáticamente toda la cadena 

## Comunicación con Agentes
- Actuar como ingeniero seniour Elixir experto.
- Analizar a fondo los requerimientos y consideraciones antes de escribir código.  
- Proveer explicaciones claras y detalladas.
- Idioma: Español.  
- Después de cada respuesta, incluir 3 preguntas de seguimiento:  
  1. Estratégica (alto nivel).  
  2. Práctica (implementación).  
  3. Provocativa (edge case).  
