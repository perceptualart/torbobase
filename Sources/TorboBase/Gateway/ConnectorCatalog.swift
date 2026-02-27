// ConnectorCatalog.swift — Static catalog of all connectors with metadata
// Torbo Base

enum ConnectorCategory: String, CaseIterable, Codable {
    case messaging = "Messaging"
    case aiVoice = "AI & Voice"
    case productivity = "Productivity"
    case developer = "Developer"
    case marketing = "Marketing"
    case social = "Social"
    case homeIoT = "Home & IoT"
    case data = "Data"

    var icon: String {
        switch self {
        case .messaging: return "bubble.left.and.bubble.right"
        case .aiVoice: return "waveform"
        case .productivity: return "doc.text"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .marketing: return "megaphone"
        case .social: return "person.2.wave.2"
        case .homeIoT: return "house"
        case .data: return "cylinder"
        }
    }
}

enum ConnectorStatus: String, Codable {
    case available
    case comingSoon
    case integrated
}

struct ConnectorConfigField: Codable, Equatable {
    let id: String
    let label: String
    let placeholder: String
    let isSecret: Bool
    var helpText: String = ""
}

struct ConnectorDefinition: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String          // SF Symbol
    let category: ConnectorCategory
    let configFields: [ConnectorConfigField]
    let status: ConnectorStatus
    var bridgeID: String?     // Maps to ChannelManager.Channel
    var providerID: String?   // Maps to CloudProvider
}

enum ConnectorCatalog {

    // MARK: - Popular IDs (top 10 shown in "Popular" filter)

    static let popularIDs: Set<String> = [
        "telegram", "discord", "slack", "anthropic", "openai",
        "notion", "github", "home_assistant", "google_calendar", "elevenlabs"
    ]

    // MARK: - All Connectors

    static let all: [ConnectorDefinition] = messaging + aiVoice + productivity + developer + marketing + social + homeIoT + data

    // MARK: - Messaging (11) — integrated via existing bridges

    private static let messaging: [ConnectorDefinition] = [
        ConnectorDefinition(
            id: "telegram", name: "Telegram", description: "Chat with agents via Telegram bot",
            icon: "paperplane.fill", category: .messaging,
            configFields: [
                ConnectorConfigField(id: "bot_token", label: "Bot Token", placeholder: "123456:ABC-DEF...", isSecret: true, helpText: "Get from @BotFather")
            ],
            status: .integrated, bridgeID: "telegram"
        ),
        ConnectorDefinition(
            id: "discord", name: "Discord", description: "Connect agents to Discord servers",
            icon: "gamecontroller.fill", category: .messaging,
            configFields: [
                ConnectorConfigField(id: "bot_token", label: "Bot Token", placeholder: "Discord bot token", isSecret: true, helpText: "From Discord Developer Portal")
            ],
            status: .integrated, bridgeID: "discord"
        ),
        ConnectorDefinition(
            id: "slack", name: "Slack", description: "Integrate agents into Slack workspaces",
            icon: "number", category: .messaging,
            configFields: [
                ConnectorConfigField(id: "bot_token", label: "Bot Token", placeholder: "xoxb-...", isSecret: true),
                ConnectorConfigField(id: "app_token", label: "App Token", placeholder: "xapp-...", isSecret: true)
            ],
            status: .integrated, bridgeID: "slack"
        ),
        ConnectorDefinition(
            id: "whatsapp", name: "WhatsApp", description: "Business API messaging integration",
            icon: "phone.fill", category: .messaging,
            configFields: [
                ConnectorConfigField(id: "api_url", label: "API URL", placeholder: "https://...", isSecret: false),
                ConnectorConfigField(id: "api_token", label: "API Token", placeholder: "Bearer token", isSecret: true),
                ConnectorConfigField(id: "verify_token", label: "Verify Token", placeholder: "Webhook verify token", isSecret: true)
            ],
            status: .integrated, bridgeID: "whatsapp"
        ),
        ConnectorDefinition(
            id: "signal", name: "Signal", description: "Private messaging via Signal CLI",
            icon: "lock.shield.fill", category: .messaging,
            configFields: [
                ConnectorConfigField(id: "api_url", label: "Signal CLI URL", placeholder: "http://localhost:8080", isSecret: false),
                ConnectorConfigField(id: "phone_number", label: "Phone Number", placeholder: "+1...", isSecret: false)
            ],
            status: .integrated, bridgeID: "signal"
        ),
        ConnectorDefinition(
            id: "imessage", name: "iMessage", description: "Send and receive iMessages (macOS only)",
            icon: "message.fill", category: .messaging,
            configFields: [],
            status: .integrated, bridgeID: "imessage"
        ),
        ConnectorDefinition(
            id: "email", name: "Email", description: "Process and send emails via IMAP/SMTP",
            icon: "envelope.fill", category: .messaging,
            configFields: [
                ConnectorConfigField(id: "imap_host", label: "IMAP Host", placeholder: "imap.gmail.com", isSecret: false),
                ConnectorConfigField(id: "smtp_host", label: "SMTP Host", placeholder: "smtp.gmail.com", isSecret: false),
                ConnectorConfigField(id: "email", label: "Email Address", placeholder: "you@example.com", isSecret: false),
                ConnectorConfigField(id: "password", label: "App Password", placeholder: "App-specific password", isSecret: true)
            ],
            status: .integrated, bridgeID: "email"
        ),
        ConnectorDefinition(
            id: "teams", name: "Microsoft Teams", description: "Connect to Microsoft Teams channels",
            icon: "person.3.fill", category: .messaging,
            configFields: [
                ConnectorConfigField(id: "webhook_url", label: "Webhook URL", placeholder: "https://...", isSecret: true)
            ],
            status: .integrated, bridgeID: "teams"
        ),
        ConnectorDefinition(
            id: "googlechat", name: "Google Chat", description: "Google Workspace chat integration",
            icon: "bubble.left.fill", category: .messaging,
            configFields: [
                ConnectorConfigField(id: "webhook_url", label: "Webhook URL", placeholder: "https://chat.googleapis.com/...", isSecret: true)
            ],
            status: .integrated, bridgeID: "googlechat"
        ),
        ConnectorDefinition(
            id: "matrix", name: "Matrix", description: "Decentralized chat via Matrix protocol",
            icon: "square.grid.3x3.fill", category: .messaging,
            configFields: [
                ConnectorConfigField(id: "homeserver", label: "Homeserver URL", placeholder: "https://matrix.org", isSecret: false),
                ConnectorConfigField(id: "access_token", label: "Access Token", placeholder: "syt_...", isSecret: true)
            ],
            status: .integrated, bridgeID: "matrix"
        ),
        ConnectorDefinition(
            id: "sms", name: "SMS", description: "Send and receive SMS messages",
            icon: "text.bubble.fill", category: .messaging,
            configFields: [
                ConnectorConfigField(id: "twilio_sid", label: "Twilio Account SID", placeholder: "AC...", isSecret: false),
                ConnectorConfigField(id: "twilio_token", label: "Auth Token", placeholder: "Twilio auth token", isSecret: true),
                ConnectorConfigField(id: "phone_number", label: "Phone Number", placeholder: "+1...", isSecret: false)
            ],
            status: .integrated, bridgeID: "sms"
        ),
    ]

    // MARK: - AI & Voice (5) — integrated via CloudProvider

    private static let aiVoice: [ConnectorDefinition] = [
        ConnectorDefinition(
            id: "anthropic", name: "Anthropic", description: "Claude models — Opus, Sonnet, Haiku",
            icon: "brain.head.profile", category: .aiVoice,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "sk-ant-...", isSecret: true)
            ],
            status: .integrated, providerID: "anthropic"
        ),
        ConnectorDefinition(
            id: "openai", name: "OpenAI", description: "GPT-4o, o1, and DALL-E models",
            icon: "circle.hexagongrid", category: .aiVoice,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "sk-...", isSecret: true)
            ],
            status: .integrated, providerID: "openai"
        ),
        ConnectorDefinition(
            id: "google_ai", name: "Google AI", description: "Gemini models via Google AI Studio",
            icon: "sparkle", category: .aiVoice,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "AI...", isSecret: true)
            ],
            status: .integrated, providerID: "google"
        ),
        ConnectorDefinition(
            id: "xai", name: "xAI", description: "Grok models from xAI",
            icon: "bolt.fill", category: .aiVoice,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "xai-...", isSecret: true)
            ],
            status: .integrated, providerID: "xai"
        ),
        ConnectorDefinition(
            id: "elevenlabs", name: "ElevenLabs", description: "Ultra-realistic AI voice synthesis",
            icon: "waveform.circle.fill", category: .aiVoice,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "ElevenLabs API key", isSecret: true)
            ],
            status: .integrated, providerID: "elevenlabs"
        ),
    ]

    // MARK: - Productivity (8) — available for configuration

    private static let productivity: [ConnectorDefinition] = [
        ConnectorDefinition(
            id: "notion", name: "Notion", description: "Read and write Notion pages and databases",
            icon: "doc.richtext", category: .productivity,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "Integration Token", placeholder: "ntn_...", isSecret: true, helpText: "Create at notion.so/my-integrations")
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "airtable", name: "Airtable", description: "Access Airtable bases and records",
            icon: "tablecells", category: .productivity,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "pat...", isSecret: true)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "google_calendar", name: "Google Calendar", description: "View and manage Google Calendar events",
            icon: "calendar", category: .productivity,
            configFields: [
                ConnectorConfigField(id: "credentials_json", label: "Service Account JSON", placeholder: "Paste JSON credentials", isSecret: true)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "google_drive", name: "Google Drive", description: "Access files on Google Drive",
            icon: "icloud", category: .productivity,
            configFields: [
                ConnectorConfigField(id: "credentials_json", label: "Service Account JSON", placeholder: "Paste JSON credentials", isSecret: true)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "dropbox", name: "Dropbox", description: "Sync and access Dropbox files",
            icon: "tray.full", category: .productivity,
            configFields: [
                ConnectorConfigField(id: "access_token", label: "Access Token", placeholder: "sl.u...", isSecret: true)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "clickup", name: "ClickUp", description: "Manage ClickUp tasks and projects",
            icon: "checkmark.circle", category: .productivity,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Token", placeholder: "pk_...", isSecret: true)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "linear", name: "Linear", description: "Track issues and projects on Linear",
            icon: "arrow.triangle.branch", category: .productivity,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "lin_api_...", isSecret: true)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "asana", name: "Asana", description: "Manage Asana tasks and workspaces",
            icon: "list.bullet.circle", category: .productivity,
            configFields: [
                ConnectorConfigField(id: "access_token", label: "Personal Access Token", placeholder: "1/...", isSecret: true)
            ],
            status: .available
        ),
    ]

    // MARK: - Developer (6) — available

    private static let developer: [ConnectorDefinition] = [
        ConnectorDefinition(
            id: "github", name: "GitHub", description: "Repos, PRs, issues, and Actions",
            icon: "chevron.left.forwardslash.chevron.right", category: .developer,
            configFields: [
                ConnectorConfigField(id: "access_token", label: "Personal Access Token", placeholder: "ghp_...", isSecret: true)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "gitlab", name: "GitLab", description: "GitLab repos, merge requests, and CI/CD",
            icon: "chevron.left.forwardslash.chevron.right", category: .developer,
            configFields: [
                ConnectorConfigField(id: "access_token", label: "Personal Access Token", placeholder: "glpat-...", isSecret: true)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "figma", name: "Figma", description: "Access Figma files and design tokens",
            icon: "paintbrush", category: .developer,
            configFields: [
                ConnectorConfigField(id: "access_token", label: "Personal Access Token", placeholder: "figd_...", isSecret: true)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "vercel", name: "Vercel", description: "Deploy and manage Vercel projects",
            icon: "arrowtriangle.up.fill", category: .developer,
            configFields: [
                ConnectorConfigField(id: "api_token", label: "API Token", placeholder: "Vercel token", isSecret: true)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "cloudflare", name: "Cloudflare", description: "Manage Cloudflare DNS, Workers, and Pages",
            icon: "cloud.fill", category: .developer,
            configFields: [
                ConnectorConfigField(id: "api_token", label: "API Token", placeholder: "Cloudflare API token", isSecret: true),
                ConnectorConfigField(id: "account_id", label: "Account ID", placeholder: "Account ID", isSecret: false)
            ],
            status: .available
        ),
        ConnectorDefinition(
            id: "firebase", name: "Firebase", description: "Firebase Auth, Firestore, and Cloud Functions",
            icon: "flame.fill", category: .developer,
            configFields: [
                ConnectorConfigField(id: "service_account_json", label: "Service Account JSON", placeholder: "Paste JSON", isSecret: true)
            ],
            status: .available
        ),
    ]

    // MARK: - Marketing (5) — coming soon

    private static let marketing: [ConnectorDefinition] = [
        ConnectorDefinition(
            id: "hubspot", name: "HubSpot", description: "CRM, contacts, and marketing automation",
            icon: "chart.bar.fill", category: .marketing,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "Private App Token", placeholder: "pat-...", isSecret: true)
            ],
            status: .comingSoon
        ),
        ConnectorDefinition(
            id: "salesforce", name: "Salesforce", description: "CRM data, leads, and opportunities",
            icon: "cloud.bolt.fill", category: .marketing,
            configFields: [
                ConnectorConfigField(id: "access_token", label: "Access Token", placeholder: "Bearer token", isSecret: true),
                ConnectorConfigField(id: "instance_url", label: "Instance URL", placeholder: "https://yourorg.my.salesforce.com", isSecret: false)
            ],
            status: .comingSoon
        ),
        ConnectorDefinition(
            id: "activecampaign", name: "ActiveCampaign", description: "Email marketing and automation",
            icon: "envelope.badge.fill", category: .marketing,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "API key", isSecret: true),
                ConnectorConfigField(id: "api_url", label: "API URL", placeholder: "https://yourorg.api-us1.com", isSecret: false)
            ],
            status: .comingSoon
        ),
        ConnectorDefinition(
            id: "brevo", name: "Brevo", description: "Transactional email and marketing campaigns",
            icon: "paperplane.circle.fill", category: .marketing,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "xkeysib-...", isSecret: true)
            ],
            status: .comingSoon
        ),
        ConnectorDefinition(
            id: "mailchimp", name: "Mailchimp", description: "Email campaigns and audience management",
            icon: "tray.and.arrow.up.fill", category: .marketing,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "key-us1", isSecret: true)
            ],
            status: .comingSoon
        ),
    ]

    // MARK: - Social (4) — coming soon

    private static let social: [ConnectorDefinition] = [
        ConnectorDefinition(
            id: "bluesky", name: "Bluesky", description: "Post and read from Bluesky social",
            icon: "cloud.sun.fill", category: .social,
            configFields: [
                ConnectorConfigField(id: "handle", label: "Handle", placeholder: "you.bsky.social", isSecret: false),
                ConnectorConfigField(id: "app_password", label: "App Password", placeholder: "App password", isSecret: true)
            ],
            status: .comingSoon
        ),
        ConnectorDefinition(
            id: "twitter", name: "X / Twitter", description: "Post tweets and read timelines",
            icon: "at", category: .social,
            configFields: [
                ConnectorConfigField(id: "bearer_token", label: "Bearer Token", placeholder: "Bearer token", isSecret: true)
            ],
            status: .comingSoon
        ),
        ConnectorDefinition(
            id: "reddit", name: "Reddit", description: "Browse and post to Reddit",
            icon: "text.bubble", category: .social,
            configFields: [
                ConnectorConfigField(id: "client_id", label: "Client ID", placeholder: "Reddit app client ID", isSecret: false),
                ConnectorConfigField(id: "client_secret", label: "Client Secret", placeholder: "Secret", isSecret: true)
            ],
            status: .comingSoon
        ),
        ConnectorDefinition(
            id: "youtube", name: "YouTube", description: "Search and analyze YouTube content",
            icon: "play.rectangle.fill", category: .social,
            configFields: [
                ConnectorConfigField(id: "api_key", label: "API Key", placeholder: "YouTube Data API key", isSecret: true)
            ],
            status: .comingSoon
        ),
    ]

    // MARK: - Home & IoT (1) — integrated

    private static let homeIoT: [ConnectorDefinition] = [
        ConnectorDefinition(
            id: "home_assistant", name: "Home Assistant", description: "Control smart home devices and automations",
            icon: "house.fill", category: .homeIoT,
            configFields: [
                ConnectorConfigField(id: "url", label: "Server URL", placeholder: "http://homeassistant.local:8123", isSecret: false),
                ConnectorConfigField(id: "access_token", label: "Long-Lived Access Token", placeholder: "eyJ...", isSecret: true)
            ],
            status: .integrated
        ),
    ]

    // MARK: - Data (2) — coming soon

    private static let data: [ConnectorDefinition] = [
        ConnectorDefinition(
            id: "databricks", name: "Databricks", description: "Query data lakehouse and run notebooks",
            icon: "square.3.layers.3d", category: .data,
            configFields: [
                ConnectorConfigField(id: "host", label: "Workspace URL", placeholder: "https://dbc-xxx.cloud.databricks.com", isSecret: false),
                ConnectorConfigField(id: "token", label: "Personal Access Token", placeholder: "dapi...", isSecret: true)
            ],
            status: .comingSoon
        ),
        ConnectorDefinition(
            id: "supabase", name: "Supabase", description: "PostgreSQL database and auth via Supabase",
            icon: "bolt.horizontal.fill", category: .data,
            configFields: [
                ConnectorConfigField(id: "url", label: "Project URL", placeholder: "https://xxx.supabase.co", isSecret: false),
                ConnectorConfigField(id: "anon_key", label: "Anon Key", placeholder: "eyJ...", isSecret: true),
                ConnectorConfigField(id: "service_role_key", label: "Service Role Key", placeholder: "eyJ...", isSecret: true, helpText: "Optional — needed for admin operations")
            ],
            status: .comingSoon
        ),
    ]

    // MARK: - Helpers

    static func connector(_ id: String) -> ConnectorDefinition? {
        all.first { $0.id == id }
    }

    static func byCategory(_ category: ConnectorCategory) -> [ConnectorDefinition] {
        all.filter { $0.category == category }
    }
}
