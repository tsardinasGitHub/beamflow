.PHONY: help setup install test quality security docs clean

# Variables
MIX = mix

help: ## Muestra esta ayuda
	@echo "Comandos disponibles:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Setup completo del proyecto
	$(MIX) deps.get
	$(MIX) assets.setup
	$(MIX) assets.build
	@echo "✓ Setup completado"

install: setup ## Alias de setup

deps: ## Instala/actualiza dependencias
	$(MIX) deps.get
	$(MIX) deps.compile

compile: ## Compila el proyecto
	$(MIX) compile --warnings-as-errors

test: ## Ejecuta todos los tests
	$(MIX) test

test.watch: ## Ejecuta tests en modo watch
	$(MIX) test.watch

coverage: ## Genera reporte de cobertura HTML
	$(MIX) coveralls.html
	@echo "✓ Reporte generado en cover/excoveralls.html"

format: ## Formatea el código
	$(MIX) format

format.check: ## Verifica formateo sin modificar
	$(MIX) format --check-formatted

credo: ## Ejecuta análisis de Credo
	$(MIX) credo --strict

credo.fix: ## Auto-corrige problemas de Credo
	$(MIX) credo --strict --fix-all

dialyzer: ## Ejecuta análisis de tipos
	$(MIX) dialyzer

security: ## Ejecuta análisis de seguridad
	$(MIX) sobelow --config

quality: format.check credo dialyzer security ## Ejecuta todos los checks de calidad
	@echo "✓ Todos los checks de calidad pasados"

quality.fix: format credo.fix ## Auto-corrige problemas de calidad
	@echo "✓ Correcciones aplicadas"

docs: ## Genera documentación
	$(MIX) docs
	@echo "✓ Documentación generada en doc/"

server: ## Inicia el servidor Phoenix
	$(MIX) phx.server

console: ## Inicia consola IEx con la aplicación
	iex -S $(MIX)

clean: ## Limpia archivos generados
	rm -rf _build
	rm -rf deps
	rm -rf .mnesia
	rm -rf cover
	rm -rf doc
	@echo "✓ Archivos generados eliminados"

clean.mnesia: ## Limpia solo base de datos Mnesia
	rm -rf .mnesia
	@echo "✓ Base de datos Mnesia eliminada"

assets.build: ## Compila assets
	$(MIX) assets.build

assets.deploy: ## Compila assets para producción
	$(MIX) assets.deploy

ci: format.check credo security test ## Ejecuta pipeline de CI local
	@echo "✓ Pipeline CI completado exitosamente"

release: ## Crea release de producción
	MIX_ENV=prod $(MIX) release

.DEFAULT_GOAL := help
