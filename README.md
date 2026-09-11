# WillChat

Cliente de chat nativo para macOS (SwiftUI) con un diseño inspirado en ChatGPT, compatible con cualquier API estilo OpenAI (OpenAI, OpenRouter, Ollama, LM Studio, vLLM…).

## Compilar

Requiere macOS 15+ y las Command Line Tools de Xcode.

```sh
make build     # genera build/WillChat.app
make install   # copia la app a /Applications
```

## Funciones

- Primer arranque guiado: URL base + API key (verificada contra `/models`) y elección de modelo.
- Barra lateral con nuevo chat (⌘N), búsqueda (⌘K), historial (⌃⌘S) y configuración (⌘,).
- Respuestas en streaming con Markdown (código, listas, tablas).
- Generación de imágenes: el modelo decide cuándo llamar a la herramienta `generate_image`, que usa `/images/generations` (o `/images/edits` para modificar la imagen anterior). Las imágenes generadas se reenvían al modelo como contexto (visión) en los siguientes mensajes.
- Los chats y las imágenes se guardan en `~/Library/Application Support/WillChat`; la API key se guarda en el Llavero.

Si tu proveedor no soporta *tool calling* o visión, desactiva esas opciones en Configuración.
