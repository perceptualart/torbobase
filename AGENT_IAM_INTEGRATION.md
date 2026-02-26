# Agent IAM Integration Guide

## Overview

The Agent Identity & Access Management (IAM) system adds production-grade security controls to Torbo Base. Every AI agent is registered, tracked, and audited. Permissions are fine-grained (per-agent, per-resource, per-action). Access is logged. Anomalies are detected.

## New Files

| File | Location | Purpose |
|------|----------|---------|
| `AgentIAM.swift` | `Gateway/` | Core IAM engine — actor-based with SQLite storage. Agent registry, permissions, access logging, anomaly detection, risk scoring. |
| `AgentIAMDashboardView.swift` | `Views/` | SwiftUI dashboard — agent list, permissions editor, access log viewer, anomaly alerts, resource search. |
| `AgentIAMDashboardHTML.swift` | `Gateway/` | Web dashboard served at `/v1/iam/dashboard` — same features as SwiftUI dashboard with real-time auto-refresh. |
| `AgentIAMRoutes.swift` | `Gateway/` | REST API routes for all IAM operations under `/v1/iam/*`. |
| `CapabilitiesIAMIntegration.swift` | `Gateway/` | Bridge between tool execution and IAM — maps tools to resources, checks permissions before execution. |
| `AgentIAMMigration.swift` | `Gateway/` | Auto-migration script — registers existing agents in IAM with permissions based on their access level. |

## API Endpoints

| Method | Path | Purpose | Access Level |
|--------|------|---------|--------------|
| GET | `/v1/iam/dashboard` | Web dashboard | chatOnly |
| GET | `/v1/iam/stats` | IAM statistics | chatOnly |
| GET | `/v1/iam/agents` | List all agents | chatOnly |
| GET | `/v1/iam/agents/{id}` | Get agent details | chatOnly |
| POST | `/v1/iam/agents/{id}/permissions` | Grant permission | fullAccess |
| DELETE | `/v1/iam/agents/{id}/permissions` | Revoke permission(s) | fullAccess |
| GET | `/v1/iam/access-log` | Query access logs | readFiles |
| GET | `/v1/iam/anomalies` | Detect anomalies | readFiles |
| GET | `/v1/iam/search?resource={pattern}` | Find agents with access | chatOnly |
| GET | `/v1/iam/risk-scores` | All risk scores | chatOnly |
| POST | `/v1/iam/prune` | Prune old logs | fullAccess |
| POST | `/v1/iam/migrate` | Trigger migration | fullAccess |

## Integration Points

### 1. GatewayServer.swift — Add IAM Routes

In `processRequest()`, add this block **before** the `// MARK: - Dashboard API` section:

```swift
// MARK: - Agent IAM
if req.path.hasPrefix("/v1/iam/") {
    // Read-only routes (list, search, stats)
    if req.method == "GET" {
        let minLevel: AccessLevel = req.path.contains("access-log") || req.path.contains("anomalies") ? .readFiles : .chatOnly
        return await guardedRoute(level: minLevel, current: currentLevel, clientIP: clientIP, req: req) {
            await AgentIAMRoutes.handleRequest(req, clientIP: clientIP) ?? HTTPResponse(statusCode: 404, headers: [:], body: Data("{\"error\":\"Not found\"}".utf8))
        }
    }
    // Write routes (grant, revoke, prune, migrate)
    if req.method == "POST" || req.method == "DELETE" {
        return await guardedRoute(level: .fullAccess, current: currentLevel, clientIP: clientIP, req: req) {
            await AgentIAMRoutes.handleRequest(req, clientIP: clientIP) ?? HTTPResponse(statusCode: 404, headers: [:], body: Data("{\"error\":\"Not found\"}".utf8))
        }
    }
}
```

### 2. AppState.swift — Initialize IAM on Startup

In the `AppState.init()` or startup sequence, add:

```swift
// Initialize IAM engine and run migration
Task {
    await AgentIAMMigration.migrateIfNeeded()
}
```

### 3. Capabilities.swift — Add IAM Checks to Tool Execution

In `executeBuiltInTools()` (or wherever tools are dispatched), add before the tool switch statement:

```swift
// IAM permission check
let iamCheck = await CapabilitiesIAM.checkBeforeToolExecution(agentID: agentID, toolName: toolName)
if !iamCheck.permitted {
    return ["error": iamCheck.reason ?? "Permission denied by IAM"]
}
```

### 4. AgentConfigManager — Sync IAM on Agent Changes

In `updateAgent()`, add after saving:

```swift
Task { await AgentIAMMigration.syncAgent(updated) }
```

In `deleteAgent()`, add after deleting the file:

```swift
Task { await AgentIAMEngine.shared.removeAgent(id) }
```

### 5. DashboardView.swift — Add IAM Tab

Add a new case to `DashboardTab`:

```swift
case iam
```

With its view:

```swift
case .iam:
    AgentIAMDashboardView()
```

And its tab button (icon: `shield.lefthalf.filled`, label: "IAM").

### 6. LinuxMain.swift — Initialize IAM on Linux

In the Linux startup sequence, add:

```swift
// IAM initialization
Task { await AgentIAMMigration.migrateIfNeeded() }
```

## Data Model

### Resource Patterns

| Pattern | Example | Matches |
|---------|---------|---------|
| `tool:{name}` | `tool:web_search` | Specific tool usage |
| `tool:*` | | Any tool usage |
| `file:{path}` | `file:/Documents/report.txt` | Specific file |
| `file:{path}/*` | `file:/Documents/*` | All files under path |
| `file:*` | | Any file |
| `*` | | Everything (wildcard) |

### Actions

| Action | Usage |
|--------|-------|
| `use` | Tool usage |
| `read` | File read |
| `write` | File write |
| `execute` | Code/command execution |
| `*` | All actions |

### Access Level → Permission Mapping

| Level | Permissions |
|-------|------------|
| 0 (OFF) | None |
| 1 (CHAT) | `tool:web_search` use, `tool:web_fetch` use |
| 2 (READ) | Level 1 + `file:*` read, `tool:list_directory` use, `tool:read_file` use, `tool:spotlight_search` use, `tool:take_screenshot` use |
| 3 (WRITE) | Level 2 + `file:*` write, `tool:write_file` use, `tool:clipboard_read` use, `tool:clipboard_write` use |
| 4 (EXEC) | Level 3 + `tool:*` use, `tool:run_command` execute, `tool:execute_code` execute |
| 5 (FULL) | `*` with `*` (full wildcard) |

## Storage

IAM data is stored in SQLite at:
```
~/Library/Application Support/TorboBase/iam.sqlite    (macOS)
~/.config/torbobase/iam.sqlite                         (Linux)
```

Migration flag file:
```
~/Library/Application Support/TorboBase/iam_migration_complete
```

## Testing Guide

### Manual Testing

1. **Verify migration**: Start the app, check logs for "IAM migration complete: X agent(s) registered"
2. **Check web dashboard**: Visit `http://127.0.0.1:4200/v1/iam/dashboard`
3. **API test — list agents**: `curl -H "Authorization: Bearer TOKEN" http://127.0.0.1:4200/v1/iam/agents`
4. **API test — grant permission**:
   ```bash
   curl -X POST -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json" \
     -d '{"resource":"tool:web_search","actions":["use"]}' \
     http://127.0.0.1:4200/v1/iam/agents/sid/permissions
   ```
5. **API test — check access log**: `curl -H "Authorization: Bearer TOKEN" http://127.0.0.1:4200/v1/iam/access-log?agent=sid`
6. **API test — anomaly detection**: `curl -H "Authorization: Bearer TOKEN" http://127.0.0.1:4200/v1/iam/anomalies`
7. **API test — resource search**: `curl -H "Authorization: Bearer TOKEN" "http://127.0.0.1:4200/v1/iam/search?resource=tool:web_search"`
8. **API test — risk scores**: `curl -H "Authorization: Bearer TOKEN" http://127.0.0.1:4200/v1/iam/risk-scores`
9. **SwiftUI dashboard**: Open the IAM tab in the desktop app dashboard

### Verify Permission Enforcement

1. Set agent access level to 1 (CHAT)
2. Try using a tool that requires higher access (e.g., `read_file`)
3. Check that the access log shows a denied entry
4. Grant the permission via API
5. Retry — should succeed
6. Check that the access log shows an allowed entry

### Verify Anomaly Detection

1. Rapidly call a tool 100+ times in a minute
2. Check `/v1/iam/anomalies` — should show "rapid_access" anomaly
3. Attempt 10+ denied actions in 5 minutes
4. Check anomalies — should show "denied_spike"

## Architecture Notes

```
Agent Request → GatewayServer
  ├── Extract agentID from header
  ├── AgentIAMEngine.checkAndLog(agentID, resource, action)
  │   ├── Check permission cache → SQLite if miss
  │   ├── Match resource pattern (glob-style)
  │   ├── Log access (always, pass or fail)
  │   └── Return allowed/denied
  ├── If denied → return 403 with reason
  └── If allowed → proceed to Capabilities.execute()

Anomaly Detection (periodic or on-demand)
  ├── Rapid access: >100 actions/minute/agent
  ├── Denied spike: >10 denials/5min/agent
  ├── Unusual resource: first-time access to resource
  └── Privilege escalation: repeated denied exec attempts

Migration (first boot)
  ├── Scan AgentConfigManager.listAgents()
  ├── Register each in IAM
  ├── Map accessLevel → permissions
  ├── Handle directoryScopes → scoped file perms
  ├── Handle enabledCapabilities → revoke disabled categories
  └── Calculate initial risk scores
```
