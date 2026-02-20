# Torbo — Privacy Policy

**Effective Date:** February 19, 2026
**Last Updated:** February 19, 2026
**Operator:** Perceptual Art LLC ("Torbo," "Company," "we," "us," or "our")

---

## Summary

**Your privacy is fundamental to Torbo.** We collect only what is necessary to provide the Service. We never sell your data. We never use your conversations to train AI models. When you use Torbo Base locally, all your data stays on your device.

---

## 1. Information We Collect

### 1.1 Account Information
- **Email address:** Required for authentication and account management
- **Account creation date and subscription status**
- **Payment information:** Processed by Stripe — we never store your full credit card number

### 1.2 Conversation Data
- **Cloud mode:** When using cloud AI providers, your conversation history is stored in our database (Supabase) to enable cross-device sync and conversation continuity. Conversations are encrypted at rest using AES-256.
- **Local mode (Torbo Base):** When running Torbo Base, all conversation data stays on your device. We never see, access, or store your local conversations.

### 1.3 Agent Configurations
- Custom agent settings, personalities, and configurations you create
- Skill configurations and preferences

### 1.4 Device Information
- Device type and operating system version (collected only when you submit feedback)
- App version number

### 1.5 Feedback Data
- If you voluntarily submit feedback: your message, feedback type, and optionally your email and device info
- Stored in Supabase and used solely for product improvement

## 2. Information We Do NOT Collect

- **We do not use your conversations to train AI models** — ever
- **We do not sell, rent, or share your personal data with third parties** for marketing or advertising
- **We do not collect telemetry, analytics, or usage tracking** — Torbo contains zero tracking code
- **We do not collect location data**
- **We do not use cookies for tracking** — only essential authentication tokens
- **We do not collect browsing history or app usage patterns**
- **We do not perform behavioral profiling**

## 3. Local vs. Cloud Data

### 3.1 Self-Hosted Torbo Base (Local Mode)
When you run Torbo Base on your own computer:
- **All data stays on your device.** Conversations, memories (Library of Alexandria), agent configurations, API keys, and all other data are stored locally.
- **Network communication is local.** The Torbo App communicates with Torbo Base over your local network or Tailscale VPN. No data passes through our servers.
- **API keys are encrypted locally.** Your API keys are stored in an encrypted keychain file (AES-256-CBC) on your device. We never see or have access to your keys.
- **We have zero visibility** into your local Torbo Base usage.

### 3.2 Cloud Mode
When you use cloud AI providers through the Torbo App without a local Base:
- Your prompts are sent directly to the AI provider (Anthropic, OpenAI, Google, xAI) using your own API keys
- Conversation history may be stored in our cloud database for sync purposes
- We do not add tracking, analytics, or metadata to your AI requests
- Each AI provider has its own privacy policy governing how they handle your prompts

## 4. Data Storage and Encryption

- **Encryption at rest:** All stored data is encrypted using AES-256 encryption
- **Encryption in transit:** All network communications use TLS/HTTPS
- **API key storage:** Encrypted with AES-256-CBC using a machine-derived key (local mode) or Supabase encrypted storage (cloud mode)
- **Authentication tokens:** Stored locally in the device's secure Keychain (iOS) or encrypted keychain file (macOS)
- **Database:** Cloud data is hosted on Supabase with row-level security and encryption at rest

## 5. Data Retention

- **Conversations:** Retained until you delete them. You may configure auto-deletion periods in Settings.
- **Account data:** Retained while your account is active. Deleted within 30 days of account closure.
- **Feedback:** Retained for product improvement purposes. You may request deletion at any time.
- **Local data (Torbo Base):** You control all retention. Clear from Settings or delete the application data directory.
- **Backups:** Cloud backups are retained for up to 30 days after deletion for disaster recovery, then permanently purged.

## 6. Third-Party Services

Torbo integrates with the following third-party services. Your use of these services is governed by their respective privacy policies:

| Service | Purpose | Data Shared |
|---------|---------|-------------|
| **Supabase** | Authentication, cloud database | Email, account data, conversation history (cloud mode) |
| **Stripe** | Payment processing | Payment information (name, card, billing address) |
| **Anthropic** | AI provider (Claude) | Your prompts and conversations (when using Claude) |
| **OpenAI** | AI provider (GPT) | Your prompts and conversations (when using GPT) |
| **Google** | AI provider (Gemini) | Your prompts and conversations (when using Gemini) |
| **xAI** | AI provider (Grok) | Your prompts and conversations (when using Grok) |
| **ElevenLabs** | Text-to-speech voices | Text content sent for voice synthesis |

**Important:** When you use an AI provider, your prompts are sent to that provider's servers under their privacy policy. We encourage you to review each provider's privacy policy. Running local models via Ollama through Torbo Base avoids sending data to any third party.

## 7. Your Rights

You have the following rights regarding your data:

### 7.1 Access
You may request a copy of all personal data we hold about you by contacting privacy@torbo.app.

### 7.2 Export
You may export all your data (conversations, agent configurations, memories) at any time through the app or by contacting us.

### 7.3 Deletion
You may delete your data at any time:
- **Conversations:** Delete individual conversations or clear all from Settings
- **Memory (LoA):** Clear all memories from Settings > Privacy & Safety
- **Account:** Request complete account deletion — all data permanently removed within 30 days
- **Local data:** Clear from Settings or delete the application data directory

### 7.4 Close Account
You may close your account at any time by contacting privacy@torbo.app. Upon closure:
- All cloud-stored data is queued for permanent deletion
- Deletion completes within 30 days
- We retain no copies after the deletion period

### 7.5 Report Violations
If you believe your privacy rights have been violated, contact privacy@torbo.app or file a complaint with your local data protection authority.

## 8. GDPR Rights (EU/EEA Users)

If you are in the EU/EEA, you additionally have the right to:
- **Rectification:** Correct inaccurate personal data
- **Restriction:** Restrict processing of your data
- **Portability:** Receive your data in a portable format
- **Object:** Object to processing based on legitimate interests
- **Withdraw consent:** Withdraw consent at any time without affecting prior processing

Our legal basis for processing: contractual necessity (providing the Service), legitimate interests (security, fraud prevention), and consent (optional features like feedback).

## 9. CCPA/CPRA Rights (California Users)

If you are a California resident:
- **We do not sell your personal information** — we never have and never will
- **We do not share your personal information** for cross-context behavioral advertising
- You have the right to know what personal information we collect and how it is used
- You have the right to delete your personal information
- You have the right to non-discrimination for exercising your rights

## 10. Children's Privacy

Torbo is not intended for children under the age of 13. We do not knowingly collect personal information from children under 13 in compliance with the Children's Online Privacy Protection Act (COPPA).

If we become aware that a child under 13 has provided us with personal information, we will promptly delete that information. If you believe a child under 13 has used Torbo, please contact us at privacy@torbo.app.

For users aged 13–17, parental consent is recommended.

## 11. Cookie and Tracking Policy

Torbo uses **minimal cookies/tokens**:

- **Authentication tokens:** Required to maintain your login session. Stored locally on your device. Not shared with third parties.
- **No tracking cookies:** We do not use cookies for analytics, advertising, or behavioral tracking.
- **No third-party trackers:** We do not embed third-party tracking scripts, pixels, or beacons.
- **No fingerprinting:** We do not use browser or device fingerprinting.

## 12. Data Breach Notification

In the event of a data breach affecting your personal information:
- We will notify affected users within 72 hours of discovery
- We will notify relevant data protection authorities as required by law
- We will provide details of the breach, potential impact, and steps taken to mitigate

## 13. Changes to This Policy

We may update this Privacy Policy from time to time. We will provide at least **30 days' notice** of material changes via email or prominent notice in the Service. Your continued use after the notice period constitutes acceptance.

The "Last Updated" date at the top of this policy indicates when changes were last made.

## 14. Contact

For questions about this Privacy Policy or to exercise your data rights:

**Perceptual Art LLC**
Email: privacy@torbo.app
Website: https://torbo.app

For data protection inquiries in the EU, you may also contact your local supervisory authority.

---

## Compliance

This Privacy Policy is designed to comply with:
- **GDPR** (EU General Data Protection Regulation)
- **CCPA/CPRA** (California Consumer Privacy Act / California Privacy Rights Act)
- **COPPA** (Children's Online Privacy Protection Act)
- **PIPEDA** (Canadian Personal Information Protection and Electronic Documents Act)
- **Apple App Store Guidelines** (Section 5.1 — Privacy)

---

© 2026 Perceptual Art LLC. All rights reserved.
