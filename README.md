# WillChat

Native macOS chat client (SwiftUI) with a ChatGPT-inspired design, compatible with any OpenAI-style API (OpenAI, OpenRouter, Ollama, LM Studio, vLLM…).

## Build

Requires macOS 15+ and Xcode Command Line Tools.

```sh
make build     # generates build/WillChat.app
make install   # copies the app to /Applications
```

## Features

- Guided first launch: base URL + API key (verified against `/models`) and model selection.
- Sidebar with new chat (⌘N), search (⌘K), history (⌃⌘S), and settings (⌘,).
- Streaming responses with Markdown (code, lists, tables).
- Regenerate the response to any of your messages (↻ button next to "Copy") using the text and image models currently selected.
- Image generation: with it enabled, replies go through the Responses API (`/responses`) with OpenAI's built-in `image_generation` tool, so the chat model decides when to create or edit an image. Generated images are sent back to the model as context (vision) in subsequent messages, which is what lets it edit them. With it disabled, replies use `/chat/completions`, which works with any OpenAI-compatible provider.
- Attachments: "+" button (⌘U), drag and drop, or paste (⌘V). Images are sent as vision; text is extracted from PDF, Word/RTF/ODT, and text or code files and included in the message. Attached images can also be edited with the image generation tool. Each attached image can be given a title in the composer, so you can refer to it by name in your message (e.g. "compare «before» with «after»" or "change the background of «logo»").
- Usage (⇧⌘U, chart button in the sidebar): tokens per day and per model, recorded from the `usage` every response reports (the first launch imports what past replies saved), plus spending read from the provider's API: OpenAI's Costs API for the whole organization (it only accepts an Admin key, which you can add in the panel and is kept in the Keychain) or OpenRouter's key and credits endpoints.
- Chats, images, attachments, and the usage log are saved in `~/Library/Application Support/WillChat`; the API key is stored in the Keychain.

If your provider doesn't support *tool calling* or vision, disable those options in Settings.
