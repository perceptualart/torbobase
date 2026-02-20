# Launch Night Summary — February 20, 2026

## Business Formation
- Torbo LLC filed in New York (DOS1336-2026-009530)
- Pricing finalized: $5/month Starter, $10/month Pro

## Intellectual Property
- TORBO trademark filed: Serial 99651006 (Feb 12, 2026)
- TORBO BASE trademark filed: Serial 99651015 (Feb 12, 2026)
- Gateway patent filed: App 63/983,058 (Feb 14, 2026) — Tiered Access Control
- 6 additional provisionals prepped for filing: Orb/Prism UI, Stream of Consciousness, Proxy Engine, Wake Word Agent Mapping, Memory Army, Voice Auto-Switching
- Platform patent identified but not yet filed: self-hosted multi-agent AI platform with local data sovereignty

## Critical Performance Fixes (all committed to main)
1. Connection Priority: Bonjour-first discovery with cascading fallback (Bonjour → local IP → .local → Tailscale → cloud). Base found in <2 seconds on local network vs 60+ seconds before.
2. Routing Fix: All requests now route through Base when connected. Previously bypassed Base and went direct to Anthropic, losing memory/LoA/tools.
3. Voice Fix: SiD's ElevenLabs voice changed from Charlotte (XB0fDUnXU5powFXDhCwa) to custom clone (iKA9xkvQHH31OepvncJY).
4. Health Check: Reduced from every 10 seconds to every 60 seconds.
5. AEC: Hardware echo cancellation enabled for speaker playback. Audio session uses .default mode with overrideOutputAudioPort(.speaker) for full volume.

## UI Overhaul (all committed to main)
- Removed undo/redo buttons from nav bar
- All nav bar icons: white when active, red when off/muted
- EKG/waveform stays green
- Added nav bar opacity slider and color hue slider in Arkhe/Appearance settings
- Onboarding redesign planned: kill cyan buttons, use glass/frosted style, real OrbViews per agent
- iPad layout polish pass needed after nav bar redesign

## Security Fixes
- Command injection fix in DocumentStore.swift
- SQL injection fix in DocumentStore.swift
- Tesla credentials removed from git tracking, Secrets.swift gitignored
- AASA file fixed: removed leaked OAuth callback paths
- Privacy policy updated: all ORB references replaced with Torbo

## App Store Compliance
- Widget branding: SiD → Torbo in all intent titles and display names
- Removed placeholder onboarding screens
- Removed Stripe checkout code and old ORB Base build artifacts

## Branding
- Dashboard renamed, sidebar reordered
- Website deployed with updated privacy policy and AASA fix

## Agent Capabilities Confirmed (first human test)
- SiD preheated car via Shortcuts
- SiD turned off lights via HomeKit
- SiD added calendar event, set reminder, sent text message
- All through natural voice conversation

## Architecture
- Torbo Base: Node.js gateway on port 4200 with mDNS/Bonjour advertisement
- iOS app: Bonjour-first discovery, routes all requests through Base when connected
- Multi-model: Anthropic, OpenAI, Google, xAI, Ollama
- 6-tier access control: OFF, CHAT, READ, WRITE, EXEC, FULL
- 4 agents: SiD, Mira, aDa, Orion
- 20 native tools

## Next Steps
- File 6 provisional patents on Patent Center
- Rotate Tesla credentials
- iPad layout polish pass
- Onboarding glass redesign
- Continue Piper voice training
