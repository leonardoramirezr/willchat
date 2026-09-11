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
- Image generation: the model decides when to call the `generate_image` tool, which uses `/images/generations` (or `/images/edits` to modify the previous image). Generated images are sent back to the model as context (vision) in subsequent messages.
- Attachments: "+" button (⌘U), drag and drop, or paste (⌘V). Images are sent as vision; text is extracted from PDF, Word/RTF/ODT, and text or code files and included in the message. Attached images can also be modified with `generate_image`. Each attached image can be given a title in the composer, so you can refer to it by name in your message (e.g. "compare «before» with «after»" or "change the background of «logo»").
- Chats, images, and attachments are saved in `~/Library/Application Support/WillChat`; the API key is stored in the Keychain.

If your provider doesn't support *tool calling* or vision, disable those options in Settings.
