# Astra

English | [简体中文](README.zh-CN.md)

Astra is a multi-provider AI chat client built on the original `chat-demo` frontend and packaged with **Tauri 2** for Android phones/tablets, Windows, and Linux. iOS is not supported.

## Features

- **Multiple providers**: built-in presets for DeepSeek, OpenAI, Anthropic, OpenRouter, Gemini, xAI, Groq, Mistral, Together, SiliconFlow, Moonshot Kimi, Zhipu, Alibaba DashScope, Volcengine Ark, MiniMax, Baidu Qianfan, Tencent Hunyuan, Ollama, and LM Studio, plus custom OpenAI-compatible endpoints.
- **Model detection**: fetch a provider's model list, classify chat/image models, and run a minimal chat test.
- **Global model switcher**: the input-area menu groups models by provider; selecting a model switches to that provider automatically.
- **Custom system prompt**: one global prompt, falling back to the provider default; one-click reset.
- **Long-term memory**: global memory with manual add/edit/delete, enable/disable, and automatic extraction after replies. Memory is injected into the system prompt.
- **Image generation**: OpenAI-compatible `/images/generations`, with in-chat images, viewing, saving, and regeneration.
- **Native networking**: the Tauri app uses Rust `reqwest`, bypassing WebView CORS and providing true SSE streaming.
- Existing features are preserved: message branches, edit/regenerate, Markdown/KaTeX/Mermaid, voice input and read-aloud, and history import/export.

## Builds

All installers are produced by GitHub Actions; no local packaging is required:

- `.github/workflows/ci.yml`: typecheck, lint, web build, and `cargo check` on pushes/PRs.
- `.github/workflows/release.yml`: on a `v*` tag or manual dispatch, produces:
  - Android (arm64, debug-signed APK that installs directly)
  - Windows (NSIS + MSI)
  - Linux (AppImage + deb)

The current `origin` points to upstream `deepseek-ai/chat-demo`; push to your own GitHub repository before running Actions.

### Local development (optional)

```sh
pnpm install
pnpm icons        # generate platform icons
pnpm tauri dev    # desktop development; the web version still works with pnpm dev
pnpm build        # web-only static bundle in dist/
pnpm tauri build  # desktop installers
```

Android builds locally require the Android SDK/NDK and Rust Android targets. CI is already configured, so local packaging is unnecessary.

## Providers and models

Open **Settings → Providers**, add a provider from a preset, enter your own API key, click **Detect models**, and choose a chat model (and an image model for image-generation providers). Presets contain connection details only — no API keys are bundled — and every field is editable.

- API keys are required for DeepSeek, OpenAI, Anthropic, and most commercial services.
- Ollama / LM Studio do not require a key by default. On Android, replace `localhost` with your computer's LAN IP and make sure both devices are on the same network.
- The DeepSeek provider preserves the original extensions: deep thinking, web search, server-side titles, speech input/read-aloud, and Files API attachments.
- **Use the native DeepSeek preset for official DeepSeek**, not the `https://api.deepseek.com/v1` OpenAI-compatible URL. The latter cannot use the thinking toggle, web search, or server-side titles; the app migrates such configurations to the native protocol.
- Official web search and server-side titles only support `deepseek-flash` (V4.1 Flash). Other models may always think and have no search/title support; the model menu shows a hint.
- OpenAI/Anthropic providers support inline image attachments only; use DeepSeek for document attachments.
- Provider base URLs may change; edit them directly in the provider editor if needed.

## Data and privacy

- Provider configuration and API keys are stored in local `localStorage` (`chat-demo:providers`).
- Chats, original attachments, generated images, and memories are stored in IndexedDB (database `chat-demo`).
- Chat, memory extraction, and image-generation requests are sent only to the selected provider.
- History export ZIPs (format v4) include chats, local images, generated images, and `memory.json`; they **exclude** API keys, provider configuration, and the system prompt.
- Import replaces chats; if the archive contains `memory.json`, memories are replaced too. Older v3 archives have no memory file, so existing memories are kept.
- “Delete all chats” keeps settings and memories. Memories can be cleared separately under **Settings → Memory**.

## Project structure

```text
src/
  app/                 App shell, theme, viewport
  components/          Chat, settings, Markdown, provider/memory/image UI
  services/
    api/               HTTP/SSE transport, DeepSeek protocol, speech, errors
    providers/         Presets, adapters, model detection, system prompt
    memory/            Memory store, prompt injection, auto extraction
    imagegen/          OpenAI-compatible image generation
    chat/              Sessions, branches, storage, history import/export
    speech/            Recording and read-aloud
src-tauri/             Tauri 2 project and Rust native HTTP/SSE commands
```

## License

[MIT](LICENSE). The upstream `deepseek-ai/chat-demo` is also MIT-licensed; third-party dependencies follow their own licenses.
