# ORB Base — Legal, Regulatory & Distribution Strategy
**Prepared for:** Michael David Murphy / Perceptual Art LLC
**Date:** February 5, 2026
**DISCLAIMER:** This document is informational guidance, not legal advice. Retain a licensed attorney before distributing software commercially.

---

## 1. DISTRIBUTION STRATEGY

### DO NOT use the Mac App Store.

ORB Base **cannot function** in the Mac App Store sandbox. The app needs to:
- Listen on TCP ports (gateway server)
- Access the local filesystem broadly
- Launch/manage Ollama processes
- Execute shell commands at higher access levels

**Mac App Store requires App Sandbox**, which blocks all of this. Apps requesting exceptions for these capabilities are routinely rejected.

### Recommended: Direct Distribution + Apple Notarization

- **Sign** with your Apple Developer ID (Developer ID Application certificate)
- **Notarize** through Apple's notary service (automated malware scan)
- **Staple** the notarization ticket to the .app bundle
- Distribute via your website as a .dmg or .zip

This is how apps like Ollama, Docker Desktop, iTerm2, Homebrew, and every serious developer tool distributes on macOS. Apple blesses it. Users can run it without Gatekeeper warnings.

**Cost:** $99/year Apple Developer Program membership (you likely already have this).

### iOS Companion App — CAN go on the App Store

The iOS companion (a remote control that connects to ORB Base on your Mac) doesn't need dangerous entitlements. It just makes HTTP requests. This one is App Store eligible.

**Requirements for iOS App Store:**
- Privacy Policy URL (created below)
- App Privacy "nutrition labels" in App Store Connect
- No hardcoded secrets
- ATS (App Transport Security) properly configured
- Age rating questionnaire (new requirement as of Jan 2026)
- Build with Xcode 16+ / iOS 18 SDK (required as of April 2026)

---

## 2. LIABILITY PROTECTION STRATEGY

### The Three Shields

**Shield 1: Corporate Entity**
- ORB Base should be published by **Perceptual Art LLC** (your existing entity), NOT by you personally
- The LLC creates a liability shield between you (Michael Murphy, individual) and any claims
- Make sure your LLC operating agreement and state filings are current
- Consider a separate LLC specifically for software products if the risk profile grows

**Shield 2: Licensing Agreement (EULA)**
The EULA (created below) includes:
- **AS-IS disclaimer** — no warranties of any kind
- **Limitation of liability** — damages capped at $0 (or price paid)
- **Indemnification** — user holds YOU harmless for their use
- **No security guarantees** — explicit statement that no software is 100% secure
- **No liability for AI actions** — user is solely responsible for what their LLMs do
- **User assumes all risk** — for data loss, breaches, unauthorized access
- **Arbitration clause** — prevents class action lawsuits
- **Governing law** — New York state, your home jurisdiction

**Shield 3: Technical Architecture**
The software itself is your best defense:
- **Local-only by default** — data never leaves the user's machine
- **No telemetry, no analytics, no cloud** — you can't leak what you never collect
- **No accounts, no user data stored by you** — nothing to breach
- **Access dial** — user explicitly chooses their risk level
- **Audit log** — proves the user was in control
- **Kill switch** — user can instantly revoke all access

This "local-first, user-controlled" architecture is your strongest legal position. You are providing a **tool**. The user operates it. You are not a service provider, data processor, or AI provider.

---

## 3. INTELLECTUAL PROPERTY — ZERO INFRINGEMENT CHECKLIST

### Code
- [x] Zero third-party dependencies (SPM package has none)
- [x] No open source libraries with copyleft licenses (GPL, AGPL)
- [x] No Apache/MIT/BSD code that requires attribution (because there is none)
- [x] All code written from scratch
- [ ] **ACTION NEEDED:** File for copyright registration with U.S. Copyright Office ($65, online, takes 3-8 months). Establishes ownership date.

### Name "ORB Base"
- [ ] **ACTION NEEDED:** Search USPTO TESS database for "ORB" and "ORB BASE" in software classes (IC 009, IC 042)
- [ ] **ACTION NEEDED:** If clear, file trademark application ($250-350 per class, online at USPTO.gov)
- [ ] Consider the name carefully — "ORB" is generic enough to potentially conflict. "ORB Base" as a compound mark is stronger.
- [ ] Search EU EUIPO database if planning European distribution

### Visual Assets
- [x] No stock images or fonts requiring commercial licenses (the app uses system SF Symbols and system fonts)
- [ ] Any custom logo/icon should be original work or properly licensed

### AI-Related IP
- You are NOT training models, NOT providing AI services, NOT creating AI outputs
- You are providing a **gateway/proxy** — legally similar to a router or firewall
- This positions you outside the scope of most AI-specific regulations (see below)

---

## 4. INTERNATIONAL REGULATORY ANALYSIS

### EU AI Act (Regulation 2024/1689)

**Status as of Feb 2026:** Prohibited practices effective since Feb 2025. GPAI model obligations effective since Aug 2025. Full high-risk system rules effective Aug 2026.

**Does it apply to ORB Base?** Almost certainly **NO**, because:
- ORB Base is NOT an AI system — it's a gateway/proxy
- It does not make decisions, generate content, or process data with AI
- It routes requests to locally-running open-source models (Ollama)
- The user controls everything
- You are not a "provider" of a GPAI model

**However:** If you market ORB Base as an "AI system" or "AI tool," you could inadvertently trigger classification. 

**Recommendation:** Market it as a **"local AI gateway"** or **"AI access control layer"** — emphasize it's infrastructure/networking software, not AI itself. Like calling it a firewall for AI rather than an AI product.

### GDPR (EU General Data Protection Regulation)

**Does it apply?** Only if you have EU users AND process their personal data.

**ORB Base's position is excellent:**
- No cloud. No accounts. No data collection. No analytics.
- All data stays on the user's local machine.
- You never see, touch, or process any user data.
- No data transfers (no servers to transfer to).

**Recommendation:** Your Privacy Policy should explicitly state you collect zero data. This is the gold standard for GDPR — you can't violate it if you never process personal data.

### CCPA / CPRA (California Consumer Privacy Act)

Same analysis as GDPR — doesn't apply if you collect no data. Your Privacy Policy covers this.

### U.S. Federal — No comprehensive AI law yet

The U.S. has no federal AI law as of Feb 2026. Executive orders exist but don't regulate consumer software tools. Several states (Colorado, Utah, Illinois) have AI-specific laws, but they target employers and high-risk decision-making, not utility software.

### Export Controls (EAR / ITAR)

**Does it apply?** NO. ORB Base:
- Contains no encryption beyond standard HTTPS/TLS (exempt under EAR §740.17)
- Is not military/intelligence technology
- Does not contain or distribute AI models (Ollama is separate software)
- Is a consumer utility application

**Recommendation:** Do not bundle Ollama models WITH the app. Keep them separate downloads. This avoids any argument that you're distributing AI models subject to export controls.

### Section 230 (Communications Decency Act)

**Relevant if** users generate harmful content through their LLMs via your gateway. Section 230 protects platforms from liability for user-generated content. Since you're providing infrastructure (like an ISP or router), this protection likely applies. Your EULA reinforces this.

---

## 5. APP STORE COMPLIANCE (iOS Companion App)

### Apple Review Guidelines Checklist

| Requirement | Status | Notes |
|-------------|--------|-------|
| Privacy Policy URL | ✅ Created below | Must be accessible via web link |
| App Privacy Labels | ⬜ TODO | Declare in App Store Connect: "Data Not Collected" |
| ATS (App Transport Security) | ⬜ CRITICAL | Remove `NSAllowsArbitraryLoads`. Use `NSAllowsLocalNetworking` ONLY |
| No hardcoded secrets | ⬜ CRITICAL | Move all tokens to Keychain |
| Background modes justified | ⬜ CHECK | Only declare modes you actually implement |
| Age rating questionnaire | ⬜ TODO | New requirement — complete by submission |
| Xcode 16 / iOS 18 SDK | ⬜ TODO | Required for submissions after April 28, 2026 |
| Minimum functionality | ✅ | App must work without the Mac companion (graceful degradation) |
| No private APIs | ✅ | All standard frameworks |
| In-App Purchase | N/A | Free app, no IAP needed initially |

### EU Digital Services Act
If distributing in EU App Store, you need **trader status** declared in App Store Connect (required since Feb 2025). This means providing your business name, address, and registration number.

---

## 6. INSURANCE RECOMMENDATION

Even with all legal protections, consider:

- **Errors & Omissions (E&O) / Professional Liability Insurance** — covers claims that your software caused harm. Typically $1,000-3,000/year for small software companies.
- **Cyber Liability Insurance** — covers data breach response costs. Since you don't hold data, this is less critical but still smart.
- **General Commercial Liability** — your LLC should already have this.

This is belt-and-suspenders protection. The EULA disclaims everything, the LLC shields you personally, and insurance covers the LLC.

---

## 7. IMMEDIATE ACTION ITEMS

**Legal (do this week):**
1. ☐ Verify Perceptual Art LLC is in good standing with your state
2. ☐ Search USPTO for "ORB BASE" trademark conflicts
3. ☐ Host Privacy Policy and EULA at a public URL (e.g., orbbase.ai or your existing domain)
4. ☐ Consider consulting an IP/software attorney for a 1-hour review of the EULA ($300-500)

**Technical (built into v2):**
1. ✅ Zero data collection architecture
2. ✅ Local-only operation
3. ✅ Access control with audit logging
4. ✅ Kill switch
5. ☐ Apple notarization pipeline (need Developer ID cert)

**Business:**
1. ☐ Register domain for the product (orbbase.com, orbbase.ai, etc.)
2. ☐ Get E&O insurance quote
3. ☐ Decide on pricing model (free? freemium? one-time purchase?)
