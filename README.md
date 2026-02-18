# Torbo Base

**Your local AI gateway. Private. Powerful. Yours.**

Torbo Base is an AI gateway that runs a local OpenAI-compatible API on your network. It routes requests to local models (via Ollama) or cloud providers (Anthropic, OpenAI, Google, xAI) — giving you a single endpoint for all your AI tools.

Any device on your network — Mac, PC, phone, tablet — can connect through the built-in web chat, management dashboard, or any OpenAI-compatible client.

## Features

- **Local inference** via Ollama — your data never leaves your machine
- **Cloud routing** — Anthropic (Claude), OpenAI (GPT), Google (Gemini), xAI (Grok) with automatic format conversion
- **OpenAI-compatible API** — works with Claude Desktop, Cursor, Continue, Open WebUI, and any OpenAI SDK client
- **Tool calling** — full support across all providers with automatic format conversion
- **Vision** — multimodal image analysis with format conversion per provider
- **Web search** — built-in DuckDuckGo search (no API key needed)
- **Text-to-speech** — ElevenLabs (premium) with OpenAI fallback
- **Speech-to-text** — OpenAI Whisper transcription
- **Image generation** — DALL-E 3 with built-in tool execution
- **Multi-agent system** — create custom agents with their own personality, role, and access level
- **Library of Alexandria (LoA)** — persistent semantic memory with entity tracking, temporal recall, and contradiction detection
- **Messaging bridges** — Telegram, Discord, Slack, Signal, WhatsApp
- **6-tier access control** — OFF → CHAT → READ → WRITE → EXEC → FULL
- **Token authentication** — secure bearer token for all API requests
- **Device pairing** — Bonjour discovery for local network clients (macOS)
- **Web chat UI** — built-in chat interface at `/chat`
- **Web dashboard** — management interface at `/dashboard`
- **Conversation persistence** — message history saved to disk
- **Audit logging** — every request logged with client IP, method, and access level
- **Rate limiting** — configurable per-minute request limits
- **Cross-platform** — macOS app with SwiftUI, headless server on Linux
- **Zero data collection** — 100% private, no telemetry, no analytics

## macOS App

### System Requirements

- **macOS 13.0 (Ventura)** or later
- **Apple Silicon or Intel Mac** — Universal Binary (arm64 + x86_64)
- [Ollama](https://ollama.com) — recommended for local model inference

### Install

1. Download **TorboBase-3.0.0.dmg** from the [latest release](https://github.com/perceptualart/torbo-base/releases/latest)
2. Open the DMG and drag **Torbo Base** to Applications
3. Launch — the setup wizard walks you through configuration

> Torbo Base is notarized and stapled by Apple. No Gatekeeper warnings.

### Build from Source (macOS)

```bash
git clone https://github.com/perceptualart/torbo-base.git
cd torbo-base
swift build
swift run TorboBase
```

## Cross-Platform (Headless Server)

Torbo Base runs as a headless server on Linux (and experimentally on Windows) with all core features: API gateway, memory system, agents, bridges, and a web-based management dashboard.

### Docker (Recommended)

The fastest way to get started. Requires [Docker](https://docs.docker.com/get-docker/).

**Quick start with Docker Compose:**

```bash
git clone https://github.com/perceptualart/torbo-base.git
cd torbo-base
cp .env.example .env       # Edit with your API keys
docker compose up -d        # Build and start in background
docker compose logs -f      # Watch logs
```

Then open `http://localhost:4200/chat` to chat, or `http://localhost:4200/dashboard` to manage the server.

**Or with plain Docker:**

```bash
docker build -t torbo-base .
docker run -d -p 4200:4200 \
  -e TORBO_HOST=0.0.0.0 \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  -v torbo-data:/home/torbo/.config/torbobase \
  --name torbo-base \
  torbo-base
```

**Connecting to Ollama on the host:**

If Ollama is running on your host machine, Docker Compose handles this automatically via `host.docker.internal`. For plain Docker, add `--add-host=host.docker.internal:host-gateway`.

**Persistent data** is stored in the `torbo-data` volume at `/home/torbo/.config/torbobase/` (agents, skills, memory, conversations, logs).

### Linux Native Build

Requires Swift 5.10+ on Ubuntu 22.04+:

```bash
# Install Swift (see https://swift.org/install)
sudo apt-get install libsqlite3-dev
git clone https://github.com/perceptualart/torbo-base.git
cd torbo-base
swift build -c release
.build/release/TorboBase
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TORBO_PORT` | `4200` | Server port |
| `TORBO_HOST` | `0.0.0.0` | Bind address (`127.0.0.1` for localhost only) |
| `TORBO_ACCESS_LEVEL` | `1` | Access level: 0=OFF, 1=CHAT, 2=READ, 3=WRITE, 4=EXEC, 5=FULL |
| `TORBO_TOKEN` | (auto-generated) | Server auth token for API requests |
| `ANTHROPIC_API_KEY` | — | Anthropic (Claude) API key |
| `OPENAI_API_KEY` | — | OpenAI (GPT) API key |
| `XAI_API_KEY` | — | xAI (Grok) API key |
| `GOOGLE_API_KEY` | — | Google (Gemini) API key |
| `ELEVENLABS_API_KEY` | — | ElevenLabs TTS API key |
| `OLLAMA_HOST` | `http://host.docker.internal:11434` | Ollama server URL |
| `TELEGRAM_BOT_TOKEN` | — | Enable Telegram bridge |
| `DISCORD_BOT_TOKEN` | — | Enable Discord bridge |
| `SLACK_BOT_TOKEN` | — | Enable Slack bridge |
| `SIGNAL_PHONE` | — | Enable Signal bridge |

## Connecting Clients

### Web Dashboard
Open `http://<your-ip>:4200/dashboard` to manage the server — configure API keys, agents, access levels, and monitor the system.

### Web Chat (any device)
Open `http://<your-ip>:4200/chat` in any browser on your network.

### OpenAI-compatible clients
Point any OpenAI SDK client at your gateway:

```
Base URL: http://<your-ip>:4200/v1
API Key: <your-server-token>
```

### Claude Desktop / Cursor / Continue
Use the base URL and token in your client's API configuration. Torbo Base translates between OpenAI, Anthropic, and Gemini formats automatically.

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
| `/v1/agents` | GET/POST | Agent management |
| `/v1/loa/*` | various | Library of Alexandria memory API |
| `/v1/dashboard/status` | GET | Server status and health |
| `/v1/config/apikeys` | GET/PUT | API key management |
| `/v1/config/settings` | GET/PUT | Server settings |
| `/v1/audit/log` | GET | Audit log |
| `/chat` | GET | Built-in web chat UI |
| `/dashboard` | GET | Management dashboard |
| `/health` | GET | Server health check |

## Architecture

Torbo Base is a native Swift application. On macOS it runs as a SwiftUI app with a full GUI. On Linux it runs as a headless server. The gateway server handles HTTP requests directly (no external web framework dependencies on macOS; SwiftNIO on Linux).

```
Sources/TorboBase/
├── App/
│   ├── TorboBaseApp.swift     # macOS SwiftUI entry point
│   └── AppState.swift         # State management, models, config
├── Platform/
│   ├── PlatformPaths.swift    # Cross-platform path resolution
│   └── LinuxMain.swift        # Headless server entry point (!macOS)
├── Gateway/
│   ├── GatewayServer.swift    # HTTP server, routing, streaming
│   ├── Capabilities.swift     # Tools, web search, TTS, STT, image gen
│   ├── ConversationStore.swift# Message persistence
│   ├── OllamaManager.swift    # Ollama lifecycle management
│   ├── WebChatHTML.swift       # Embedded web chat UI
│   ├── DashboardHTML.swift     # Web management dashboard
│   ├── Memory/                # Library of Alexandria (LoA)
│   │   ├── MemoryArmy.swift   # Librarian, Searcher, Repairer, Watcher
│   │   ├── MemoryIndex.swift  # SQLite + vector embeddings
│   │   └── BM25Index.swift    # BM25 keyword search
│   └── ...
└── Views/                     # macOS SwiftUI views
    ├── DashboardView.swift
    ├── SetupWizardView.swift
    └── ...
```

## Security

- API keys encrypted at rest (AES-256-CBC with machine-derived key)
- Bearer token required for all API requests
- **6-tier access control** — OFF → CHAT → READ → WRITE → EXEC → FULL
- **18-layer defense** — auth, CORS, CSP, path enforcement, command allowlist, HMAC webhooks, SQL prepared statements, buffer limits, rate limiting, and more
- Per-agent directory scoping on file tools
- Full audit log of all requests
- Kill switch for instant access revocation

## Built By

[Michael David Murphy](https://perceptualart.com) & SiD (Claude Opus 4.6, Anthropic)

## License

Proprietary — Copyright 2026 Perceptual Art LLC. All rights reserved.

See [LICENSE](LICENSE) for details.

"Torbo", "Torbo Base", and the Torbo logo are trademarks of Perceptual Art LLC.
