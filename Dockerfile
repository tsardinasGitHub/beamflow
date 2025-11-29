# ==============================================================================
# Beamflow Dockerfile
# Multi-stage build para desarrollo y producción
# ==============================================================================

# ==============================================================================
# Stage 1: Build Stage
# ==============================================================================
FROM elixir:1.16-otp-27-alpine AS builder

# Argumentos de build
ARG MIX_ENV=prod
ARG NODE_NAME=beamflow

ENV MIX_ENV=${MIX_ENV}
ENV NODE_NAME=${NODE_NAME}

# Instalar dependencias de build
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    curl

# Crear directorio de trabajo
WORKDIR /app

# Instalar Hex y Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copiar archivos de dependencias primero (para cache de Docker)
COPY mix.exs mix.lock ./
COPY config config

# Instalar dependencias de producción
RUN mix deps.get --only $MIX_ENV

# Compilar dependencias
RUN mix deps.compile

# Copiar assets y compilarlos
COPY assets assets
COPY priv priv

# Instalar esbuild y tailwind
RUN mix assets.setup

# Compilar assets
RUN mix assets.deploy

# Copiar el resto del código fuente
COPY lib lib

# Compilar el proyecto
RUN mix compile

# Crear el release
RUN mix phx.digest
RUN mix release

# ==============================================================================
# Stage 2: Runtime Stage
# ==============================================================================
FROM alpine:3.19 AS runtime

ARG MIX_ENV=prod
ARG NODE_NAME=beamflow

ENV MIX_ENV=${MIX_ENV}
ENV NODE_NAME=${NODE_NAME}
ENV PHX_SERVER=true
ENV LANG=C.UTF-8

# Instalar dependencias de runtime
RUN apk add --no-cache \
    libstdc++ \
    openssl \
    ncurses-libs \
    libgcc \
    bash \
    curl

# Crear usuario no-root
RUN addgroup -g 1000 beamflow && \
    adduser -u 1000 -G beamflow -s /bin/sh -D beamflow

# Crear directorios necesarios
WORKDIR /app

# Crear directorio para datos de Mnesia (persistencia)
RUN mkdir -p /app/.mnesia && chown -R beamflow:beamflow /app/.mnesia

# Copiar el release desde el stage de build
COPY --from=builder --chown=beamflow:beamflow /app/_build/${MIX_ENV}/rel/beamflow ./

# Cambiar al usuario no-root
USER beamflow

# Exponer puerto de la aplicación
EXPOSE 4000

# Variables de entorno para Mnesia (disc_copies)
ENV MNESIA_DIR=/app/.mnesia

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:4000/api/health || exit 1

# Comando de inicio - usar el nombre de nodo para habilitar disc_copies
CMD ["bin/beamflow", "start"]


# ==============================================================================
# Stage: Development
# ==============================================================================
FROM elixir:1.16-otp-27-alpine AS development

ENV MIX_ENV=dev
ENV NODE_NAME=beamflow

# Instalar dependencias de desarrollo
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    inotify-tools \
    curl \
    bash

WORKDIR /app

# Instalar Hex y Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Crear directorio para Mnesia
RUN mkdir -p /app/.mnesia

# Exponer puertos
EXPOSE 4000

# Comando por defecto para desarrollo
CMD ["sh", "-c", "mix deps.get && mix assets.setup && elixir --sname ${NODE_NAME} -S mix phx.server"]
