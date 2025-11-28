# 📸 Guía de Capturas de Pantalla

Este directorio contiene las imágenes del dashboard para documentación.

## Imágenes Requeridas

### Screenshots Principales

| Archivo | Descripción | Dimensiones |
|---------|-------------|-------------|
| `dashboard-explorer.png` | Vista del Workflow Explorer con lista de workflows | 1280x720 |
| `dashboard-details.png` | Vista de detalles con timeline de eventos | 1280x720 |
| `dashboard-graph.png` | Vista del grafo SVG con nodos coloreados | 1280x720 |
| `dashboard-analytics.png` | Vista de analytics con KPIs y gráficos | 1280x720 |
| `dashboard-replay.png` | Grafo en modo replay con controles | 1280x720 |

### GIF Animado

| Archivo | Descripción | Duración |
|---------|-------------|----------|
| `replay-mode.gif` | Demo del modo replay mostrando navegación temporal | 10-15 seg |

## Cómo Capturar

### Screenshots

1. Iniciar la aplicación: `mix phx.server`
2. Ejecutar demo setup: `mix run scripts/demo_setup.exs --count 15`
3. Esperar 10 segundos para que los workflows se ejecuten
4. Navegar a cada vista y capturar con:
   - Windows: `Win + Shift + S`
   - Mac: `Cmd + Shift + 4`
   - Linux: `gnome-screenshot` o similar

### GIF del Replay Mode

Herramientas recomendadas:
- **Windows**: ScreenToGif (https://www.screentogif.com/)
- **Mac**: Gifox o Kap
- **Linux**: Peek

Pasos:
1. Navegar a un workflow completado
2. Abrir vista de grafo
3. Activar modo replay
4. Grabar:
   - Click en Rewind
   - Click en Play
   - Dejar reproducir hasta el final
   - Click en slider para saltar
5. Exportar como GIF (max 5MB para GitHub)

## Optimización

Para mantener el repo liviano:

```bash
# Optimizar PNGs
pngquant --quality=65-80 *.png

# Optimizar GIF (reducir frames)
gifsicle -O3 --colors 128 replay-mode.gif -o replay-mode-optimized.gif
```

## Placeholder

Mientras no existan las imágenes reales, el README usa badges de placeholder.
Una vez capturadas, actualizar los links en:
- `README.md`
- `docs/DEMO_GUIDE.md`
