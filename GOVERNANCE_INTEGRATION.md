# Governance & Observability — Integration Guide

## New Files Created

| File | Location | Purpose |
|------|----------|---------|
| `GovernanceEngine.swift` | `Sources/TorboBase/Gateway/` | Core actor — SQLite audit trail, policy enforcement, approval gates, cost tracking, anomaly detection |
| `GovernanceDashboardView.swift` | `Sources/TorboBase/Views/` | SwiftUI macOS dashboard — real-time activity feed, approval queue, cost charts |
| `GovernanceDashboardHTML.swift` | `Sources/TorboBase/Gateway/` | Web dashboard (HTML/CSS/JS) — same features, for Linux/headless/browser access |
| `GovernanceRoutes.swift` | `Sources/TorboBase/Gateway/` | API route handler — all `/v1/governance/*` endpoints |

---

## Integration Steps

### 1. GatewayServer.swift — Add Route Handler

Add to the `route()` function in GatewayServer.swift, after the existing LoA routes block (around line 1024) and before the HomeKit routes:

```swift
// MARK: - Governance & Observability
if req.path.hasPrefix("/v1/governance") {
    if let (status, body) = await GovernanceRoutes.handle(
        method: req.method, path: req.path,
        body: req.jsonBody, queryParams: req.queryParams
    ) {
        // Handle raw data exports (CSV/JSON file downloads)
        if let dict = body as? [String: Any], dict["__raw_data"] as? Bool == true {
            let contentType = dict["__content_type"] as? String ?? "application/json"
            let disposition = dict["__disposition"] as? String ?? ""
            let bytes = dict["__bytes"] as? [UInt8] ?? []
            var headers = ["Content-Type": contentType]
            if !disposition.isEmpty { headers["Content-Disposition"] = disposition }
            return HTTPResponse(statusCode: status, headers: headers, body: Data(bytes))
        }
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: data)
        }
    }
    return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                      body: Data("{\"error\":\"Unknown governance route\"}".utf8))
}
```

### 2. GatewayServer.swift — Add Web Dashboard Route

Add near the existing `/dashboard` route (around line 750):

```swift
// Governance web dashboard
if req.method == "GET" && req.path == "/governance" {
    return HTTPResponse(statusCode: 200,
                      headers: [
                        "Content-Type": "text/html; charset=utf-8",
                        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'none'; frame-src 'none'; object-src 'none'",
                        "X-Frame-Options": "DENY",
                        "X-Content-Type-Options": "nosniff"
                      ],
                      body: Data(GovernanceDashboardHTML.page.utf8))
}
```

### 3. AppState.swift — Add Governance Tab (Optional)

Add a new case to the `DashboardTab` enum:

```swift
case governance = "Governance"
```

Add to the `icon` computed property:
```swift
case .governance: return "shield.lefthalf.filled"
```

Add to the `hint` computed property:
```swift
case .governance: return "governance"
```

### 4. DashboardView.swift — Add Tab Content (Optional)

In the tab content switch statement, add:

```swift
case .governance:
    GovernanceDashboardView()
```

### 5. Capabilities.swift — Log Decisions Before/After Tool Execution (Optional)

To log governance decisions for every tool execution, add to the tool execution flow in Capabilities.swift. In the main `executeBuiltInTools` function, before executing each tool:

```swift
// Log tool execution to governance
Task {
    let engine = GovernanceEngine.shared
    await engine.initialize()
    _ = await engine.logDecision(
        agent: agentID ?? "unknown",
        action: toolName,
        reasoning: "Tool execution requested",
        confidence: 1.0,
        cost: 0.0,  // Set actual cost if known
        riskLevel: .low
    )
}
```

### 6. LinuxMain.swift — Initialize on Startup (Optional)

Add to the Linux startup sequence:

```swift
Task { await GovernanceEngine.shared.initialize() }
```

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/governance` | Discovery — lists all available endpoints |
| GET | `/v1/governance/decisions?limit=50&offset=0` | List decisions (paginated) |
| GET | `/v1/governance/decisions/{id}` | Decision detail with full trace (explainability) |
| POST | `/v1/governance/decisions` | Log a decision manually |
| GET | `/v1/governance/stats` | Aggregate statistics |
| GET | `/v1/governance/approvals` | List pending approval requests |
| POST | `/v1/governance/approve/{id}` | Approve a pending decision |
| POST | `/v1/governance/reject/{id}` | Reject a pending decision |
| GET | `/v1/governance/policies` | List governance policies |
| PUT | `/v1/governance/policies` | Replace all policies |
| GET | `/v1/governance/anomalies` | List detected anomalies |
| POST | `/v1/governance/anomalies` | Trigger anomaly detection scan |
| GET | `/v1/governance/audit/export?format=json\|csv` | Export full audit trail |
| GET | `/governance` | Web dashboard UI |

---

## Example API Calls

### Log a decision
```bash
curl -X POST http://localhost:4200/v1/governance/decisions \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agentID": "sid",
    "action": "web_search",
    "reasoning": "User asked about weather",
    "confidence": 0.95,
    "cost": 0.002,
    "riskLevel": "low",
    "outcome": "success"
  }'
```

### Get stats
```bash
curl http://localhost:4200/v1/governance/stats \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### List recent decisions
```bash
curl "http://localhost:4200/v1/governance/decisions?limit=20" \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### Get decision trace (explainability)
```bash
curl http://localhost:4200/v1/governance/decisions/DECISION_UUID \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### Approve a pending action
```bash
curl -X POST http://localhost:4200/v1/governance/approve/DECISION_UUID \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"approvedBy": "admin"}'
```

### Export audit trail as CSV
```bash
curl "http://localhost:4200/v1/governance/audit/export?format=csv" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -o governance-export.csv
```

### Update policies
```bash
curl -X PUT http://localhost:4200/v1/governance/policies \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "policies": [
      {
        "id": "custom-guard",
        "name": "Custom File Guard",
        "enabled": true,
        "riskLevel": "HIGH",
        "actionPattern": "*delete*",
        "requireApproval": true,
        "maxCostPerAction": 0,
        "blockedAgents": [],
        "description": "Require approval for any delete operation"
      }
    ]
  }'
```

### Trigger anomaly scan
```bash
curl -X POST http://localhost:4200/v1/governance/anomalies \
  -H "Authorization: Bearer YOUR_TOKEN"
```

---

## Testing

### 1. Unit test — Log and retrieve
```bash
# Log a test decision
curl -X POST http://localhost:4200/v1/governance/decisions \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agentID":"sid","action":"test_action","reasoning":"Testing governance","confidence":0.9,"cost":0.01}'

# Verify it appears in stats
curl http://localhost:4200/v1/governance/stats -H "Authorization: Bearer YOUR_TOKEN"

# Verify it appears in decisions list
curl "http://localhost:4200/v1/governance/decisions?limit=5" -H "Authorization: Bearer YOUR_TOKEN"
```

### 2. Web dashboard test
Open `http://localhost:4200/governance` in a browser.

### 3. Policy enforcement test
```bash
# Get current policies
curl http://localhost:4200/v1/governance/policies -H "Authorization: Bearer YOUR_TOKEN"

# Log a high-cost action (should be blocked by default $1.00 policy)
curl -X POST http://localhost:4200/v1/governance/decisions \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agentID":"sid","action":"expensive_action","cost":5.00}'

# Verify it was blocked
curl "http://localhost:4200/v1/governance/decisions?limit=1" -H "Authorization: Bearer YOUR_TOKEN"
```

### 4. Export test
```bash
curl "http://localhost:4200/v1/governance/audit/export?format=json" \
  -H "Authorization: Bearer YOUR_TOKEN" | python3 -m json.tool

curl "http://localhost:4200/v1/governance/audit/export?format=csv" \
  -H "Authorization: Bearer YOUR_TOKEN" | head -5
```

---

## Storage

The governance database is stored at:
- **macOS**: `~/Library/Application Support/TorboBase/governance/governance.db`
- **Linux**: `~/.config/torbobase/governance/governance.db`

Uses SQLite with WAL mode for concurrent reads. Tables:
- `decisions` — Full audit trail of every AI decision
- `policies` — Governance policy rules
- `anomalies` — Detected behavioral anomalies
- `cost_tracking` — Aggregated cost per agent per day

---

## Architecture

```
Request → GatewayServer
  → /v1/governance/* → GovernanceRoutes.handle()
      → GovernanceEngine.shared (actor)
          → SQLite (governance.db)
          → In-memory caches (decisions, policies, anomalies, costs)
          → Approval continuations (async/await)

  → /governance → GovernanceDashboardHTML.page (web UI)
      → Polls /v1/governance/* APIs every 5 seconds

  → SwiftUI DashboardView → GovernanceDashboardView
      → Calls GovernanceEngine.shared directly
```

Default policies installed on first run:
1. **File Deletion Guard** — Requires approval for delete operations
2. **Shell Execution Monitor** — Flags shell commands for audit
3. **High Cost Guard** — Blocks actions costing > $1.00
4. **Code Execution Guard** — Requires approval for sandbox execution
5. **System Access Monitor** — Monitors system-level access
6. **External Web Request Monitor** — Tracks web requests, blocks > $0.50
