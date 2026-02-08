# ORB Base

**Your local AI gateway. Private. Powerful. Yours.**

ORB Base is a macOS application that runs a local OpenAI-compatible API gateway on your network. It routes requests to local models (via Ollama) or cloud providers (Anthropic, OpenAI, Google) — giving you a single endpoint for all your AI tools.

Any device on your network — Mac, PC, phone, tablet — can connect through the built-in web chat or any OpenAI-compatible client.

## Features

- **Local inference** via Ollama — your data never leaves your machine
- **Cloud routing** — Anthropic (Claude), OpenAI (GPT), Google (Gemini) with automatic format conversion
- **OpenAI-compatible API** — works with Claude Desktop, Cursor, Continue, Open WebUI, and any OpenAI SDK client
- **Tool calling** — full support across all providers with automatic format conversion
- **Vision** — multimodal image analysis with format conversion per provider
- **Web search** — built-in DuckDuckGo search (no API key needed)
- **Text-to-speech** — ElevenLabs (premium) with OpenAI fallback
- **Speech-to-text** — OpenAI Whisper transcription
- **Image generation** — DALL-E 3 with built-in tool execution
- **6-tier access control** — OFF → CHAT → READ → WRITE → EXEC → FULL
- **Token authentication** — secure bearer token for all API requests
- **Device pairing** — Bonjour discovery for local network clients
- **Conversation persistence** — message history saved to disk
- **Audit logging** — every request logged with client IP, method, and access level
- **Rate limiting** — configurable per-minute request limits
- **Kill switch** — instant access revocation from the ORB
- **Web chat UI** — built-in chat interface at `/chat` for any browser
- **Zero data collection** — 100% private, no telemetry, no analytics

## Requirements

- macOS 14 (Sonoma) or later
- [Ollama](https://ollama.com) (optional, for local models)
- API keys for cloud providers (optional)

## Quick Start

```bash
git clone https://github.com/perceptualart/ORBBase.git
cd ORBBase
swift build
swift run ORBBase
```

The setup wizard will walk you through configuration on first launch.

## Connecting Clients

### Web Chat (any device)
Open `http://<your-ip>:4200/chat` in any browser on your network.

### OpenAI-compatible clients
Point any OpenAI SDK client at your gateway:

```
Base URL: http://<your-ip>:4200/v1
API Key: <your-server-token>
```

### Claude Desktop / Cursor / Continue
Use the base URL and token in your client's API configuration. ORB Base translates between OpenAI, Anthropic, and Gemini formats automatically.

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/v1/chat/completions` | POST | Chat completions (streaming + non-streaming) |
| `/v1/models` | GET | List available models (local + cloud) |
| `/v1/capabilities` | GET | Feature manifest |
| `/v1/audio/speech` | POST | Text-to-speech |
| `/v1/audio/transcriptions` | POST | Speech-to-text |
| `/v1/images/generations` | POST | Image generation |
| `/v1/search` | POST | Web search |
| `/v1/fetch` | POST | Web page content extraction |
| `/chat` | GET | Built-in web chat UI |
| `/health` | GET | Server health check |

## Architecture

ORB Base is a native Swift application built with SwiftUI. The gateway server handles HTTP requests directly (no external web framework dependencies).

```
Sources/ORBBase/
├── App/
│   ├── ORBBaseApp.swift        # App entry point
│   └── AppState.swift          # State management, models, config
├── Gateway/
│   ├── GatewayManager.swift    # HTTP server, routing, streaming
│   ├── Capabilities.swift      # Web search, TTS, STT, image gen, tool processing
│   ├── ConversationStore.swift # Message persistence
│   ├── OllamaManager.swift     # Ollama lifecycle management
│   ├── WebChatHTML.swift        # Embedded web chat UI
│   └── ...
└── Views/
    ├── DashboardView.swift     # Main dashboard
    ├── SetupWizardView.swift   # First-launch wizard
    └── ...
```

## Security

- All API keys stored in macOS Keychain
- Bearer token required for all API requests
- 6-tier access control limits what clients can do
- Sandbox paths restrict file access to approved directories
- Rate limiting prevents abuse
- Full audit log of all requests
- Kill switch for instant access revocation

## Built By

[Michael David Murphy](https://perceptualart.com) & Orion (Claude Opus 4.6, Anthropic)

## License

Proprietary — Copyright © 2026 Perceptual Art LLC. All rights reserved.

See [LICENSE](LICENSE) for details.

"ORB", "ORB Base", and the ORB logo are trademarks of Perceptual Art LLC.
