<div align="center">
  <img src="assets/app_icon.png" alt="Kelivo Icon" width="100" />
  <h1>Kelivo</h1>

A Flutter LLM chat client for Android and macOS.
</div>

## Features

- **Multi-provider** — OpenAI, Google Gemini, Anthropic, and other major providers.
- **Custom assistants** — create and manage personalized assistants with their own prompts and settings.
- **Multimodal input** — images, text documents, PDFs, Word documents.
- **Markdown rendering** — code highlighting, LaTeX, tables.
- **Memory** — plain Markdown files the model reads, searches, and edits through tools.
- **MCP** — Model Context Protocol tool integration, including a built-in Fetch tool.
- **Web search** — Bing, DuckDuckGo, Exa, Tavily, Zhipu, LinkUp, Brave, Metaso, SearXNG, Ollama, Jina, Perplexity, Bocha, Serper, Grok.
- **Voice / TTS** — system TTS plus OpenAI, Google Gemini, and ElevenLabs voices.
- **Data backup** — chat history backup and restore.
- **Material You** — dynamic color theming (Android 12+) and a dark theme.
- **Localization** — English and Chinese.

## Platforms

- Android
- macOS

## Development

Requires Flutter 3.44.9 (see `.github/workflows/pr-check.yml`).

```bash
flutter pub get
flutter run
```

All three must pass before committing:

```bash
dart format lib test
dart analyze --fatal-infos lib test
flutter test
```

See [AGENTS.md](AGENTS.md) for architecture and code style.

## Acknowledgements

Forked from [Kelivo](https://github.com/Chevey339/kelivo). UI design inspired by
[RikkaHub](https://github.com/re-ovo/rikkahub).

## License

AGPL-3.0 — see [LICENSE](LICENSE).
