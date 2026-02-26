# New API Endpoints — Phase 6

**Date:** 2026-02-26
**Base URL:** `http://127.0.0.1:4200`
**Auth:** Bearer token in `Authorization` header (all endpoints unless noted)

---

## Access Levels

| Level | Name | Value | Description |
|-------|------|-------|-------------|
| 0 | off | `.off` | No access |
| 1 | chatOnly | `.chatOnly` | Read-only, chat |
| 2 | readFiles | `.readFiles` | + Read files |
| 3 | writeFiles | `.writeFiles` | + Write files |
| 4 | execute | `.execute` | + Run commands, modify data |
| 5 | fullAccess | `.fullAccess` | Full system access |

---

## 1. Governance API — `/v1/governance/`

**File:** `GovernanceRoutes.swift`
**Purpose:** AI decision audit trail, policy enforcement, approval gates, anomaly detection.

| # | Method | Path | Auth | Description |
|---|--------|------|------|-------------|
| 1 | GET | `/v1/governance` | chatOnly | Discovery — list all governance endpoints |
| 2 | GET | `/v1/governance/decisions` | chatOnly | List decisions (paginated: `?limit=50&offset=0`) |
| 3 | GET | `/v1/governance/decisions/{id}` | chatOnly | Decision detail with full explainability trace |
| 4 | POST | `/v1/governance/decisions` | execute | Log decision manually |
| 5 | GET | `/v1/governance/stats` | chatOnly | Aggregate statistics (total, costs, anomalies) |
| 6 | POST | `/v1/governance/approve/{id}` | fullAccess | Approve pending decision |
| 7 | POST | `/v1/governance/reject/{id}` | fullAccess | Reject pending decision |
| 8 | GET | `/v1/governance/approvals` | chatOnly | List pending approval requests |
| 9 | GET | `/v1/governance/policies` | chatOnly | List governance policies |
| 10 | PUT | `/v1/governance/policies` | fullAccess | Replace all policies |
| 11 | GET | `/v1/governance/anomalies` | chatOnly | List detected anomalies |
| 12 | POST | `/v1/governance/anomalies` | execute | Trigger anomaly detection scan |
| 13 | GET | `/v1/governance/audit/export` | fullAccess | Export audit trail (`?format=json|csv&limit=1000`) |

### Request/Response Examples

**POST `/v1/governance/decisions`**
```json
{
  "action": "web_search",
  "agent_id": "sid",
  "reasoning": "User asked about weather",
  "confidence": 0.95,
  "cost": 0.002,
  "risk_level": "low"
}
```

**GET `/v1/governance/decisions/{id}`** → Response:
```json
{
  "decision": {
    "id": "abc123",
    "timestamp": "2026-02-26T08:00:00Z",
    "agentID": "sid",
    "action": "web_search",
    "reasoning": "User asked about weather",
    "confidence": 0.95,
    "cost": 0.002,
    "riskLevel": "low",
    "policyResult": "allowed",
    "approvalStatus": "not_required"
  },
  "trace": {
    "relatedDecisions": [],
    "policyChecks": [{"rule": "default_allow", "result": "allowed"}],
    "costBreakdown": {"inference": 0.001, "tools": 0.001}
  }
}
```

**PUT `/v1/governance/policies`**
```json
{
  "policies": [
    {
      "name": "block_dangerous_commands",
      "enabled": true,
      "action_pattern": "run_command",
      "max_cost": null,
      "requires_approval": false,
      "blocked_agents": ["mira", "ada"]
    }
  ]
}
```

---

## 2. IAM API — `/v1/iam/`

**File:** `AgentIAMRoutes.swift`
**Purpose:** Agent identity management, fine-grained permissions, access logging, anomaly detection.

| # | Method | Path | Auth | Description |
|---|--------|------|------|-------------|
| 1 | GET | `/v1/iam/dashboard` | readFiles | Serve IAM web dashboard (HTML) |
| 2 | GET | `/v1/iam/stats` | chatOnly | IAM statistics |
| 3 | GET | `/v1/iam/agents` | chatOnly | List all agents (`?owner=michael`) |
| 4 | GET | `/v1/iam/agents/{id}` | chatOnly | Agent detail with permissions and risk score |
| 5 | POST | `/v1/iam/agents/{id}/permissions` | execute | Grant permission |
| 6 | DELETE | `/v1/iam/agents/{id}/permissions` | execute | Revoke permissions (`?resource=file:*`) |
| 7 | GET | `/v1/iam/access-log` | chatOnly | Query access logs (`?agent=sid&resource=file:*&limit=100&offset=0`) |
| 8 | GET | `/v1/iam/anomalies` | chatOnly | Detected access anomalies |
| 9 | GET | `/v1/iam/search` | chatOnly | Find agents with access to resource (`?resource=tool:web_search`) |
| 10 | GET | `/v1/iam/risk-scores` | chatOnly | All agent risk scores |
| 11 | POST | `/v1/iam/prune` | fullAccess | Prune old access logs (`?days=30`) |
| 12 | POST | `/v1/iam/migrate` | fullAccess | Trigger migration of existing agents |

### Request/Response Examples

**POST `/v1/iam/agents/{id}/permissions`**
```json
{
  "resource": "file:/Documents/*",
  "actions": ["read", "write"],
  "grantedBy": "michael"
}
```

**GET `/v1/iam/agents/{id}`** → Response:
```json
{
  "id": "sid",
  "owner": "system",
  "purpose": "Primary intelligence",
  "createdAt": "2026-02-01T00:00:00Z",
  "permissions": [
    {
      "resource": "tool:*",
      "actions": ["use"],
      "grantedAt": "2026-02-01T00:00:00Z",
      "grantedBy": "system"
    }
  ],
  "riskScore": 0.15
}
```

**GET `/v1/iam/anomalies`** → Response:
```json
{
  "anomalies": [
    {
      "type": "rapid_access",
      "agentID": "orion",
      "description": "150 actions in last minute (threshold: 100)",
      "severity": "medium",
      "detectedAt": "2026-02-26T08:30:00Z"
    }
  ]
}
```

---

## 3. Teams API — `/v1/teams/`

**File:** `AgentTeamsRoutes.swift`
**Purpose:** Multi-agent team management and coordinated task execution.

| # | Method | Path | Auth | Description |
|---|--------|------|------|-------------|
| 1 | GET | `/v1/teams` | chatOnly | List all teams |
| 2 | POST | `/v1/teams` | execute | Create team |
| 3 | GET | `/v1/teams/{id}` | chatOnly | Team detail |
| 4 | PUT | `/v1/teams/{id}` | execute | Update team |
| 5 | DELETE | `/v1/teams/{id}` | execute | Delete team |
| 6 | POST | `/v1/teams/{id}/execute` | execute | Execute team task |
| 7 | GET | `/v1/teams/{id}/executions` | chatOnly | Execution history (`?limit=50`) |
| 8 | GET | `/v1/teams/{id}/context` | chatOnly | Get shared context |
| 9 | PUT | `/v1/teams/{id}/context` | execute | Update shared context |

### Request/Response Examples

**POST `/v1/teams`**
```json
{
  "name": "Research Team",
  "coordinator": "sid",
  "members": ["orion", "mira"],
  "description": "Research and analysis team"
}
```

**POST `/v1/teams/{id}/execute`**
```json
{
  "description": "Research the latest developments in quantum computing and write a summary report with key takeaways"
}
```
→ Response:
```json
{
  "execution_id": "exec_abc123",
  "status": "completed",
  "subtasks": [
    {"agent": "orion", "description": "Research quantum computing developments", "status": "completed"},
    {"agent": "mira", "description": "Compile and format summary report", "status": "completed"}
  ],
  "result": "## Quantum Computing Summary 2026\n...",
  "elapsed": 12.5
}
```

**PUT `/v1/teams/{id}/context`**
```json
{
  "key": "research_focus",
  "value": "quantum error correction"
}
```
or bulk:
```json
{
  "entries": {
    "topic": "quantum computing",
    "deadline": "2026-03-01"
  }
}
```
or clear:
```json
{
  "clear": true
}
```

---

## 4. Visual Workflows API — `/v1/visual-workflows/`

**File:** `WorkflowRoutes.swift`
**Purpose:** CRUD and execution of visual node-graph workflows.

| # | Method | Path | Auth | Description |
|---|--------|------|------|-------------|
| 1 | GET | `/v1/visual-workflows` | chatOnly | List all workflows |
| 2 | POST | `/v1/visual-workflows` | execute | Create workflow |
| 3 | GET | `/v1/visual-workflows/{id}` | chatOnly | Workflow detail (nodes, connections, config) |
| 4 | PUT | `/v1/visual-workflows/{id}` | execute | Update workflow (partial or full) |
| 5 | DELETE | `/v1/visual-workflows/{id}` | execute | Delete workflow |
| 6 | POST | `/v1/visual-workflows/{id}/execute` | execute | Execute workflow |
| 7 | GET | `/v1/visual-workflows/{id}/executions` | chatOnly | Execution history (`?limit=50`) |
| 8 | POST | `/v1/visual-workflows/{wfID}/approve/{execID}` | execute | Approve/reject execution at approval node |
| 9 | GET | `/v1/visual-workflows/templates` | chatOnly | List workflow templates |
| 10 | POST | `/v1/visual-workflows/from-template/{name}` | execute | Create from template |

### Node Types

| Kind | Description | Config Keys |
|------|-------------|-------------|
| `trigger` | Start node | `trigger_type`, `cron_expression`, `webhook_path`, `telegram_command`, `email_filter`, `file_path` |
| `agent` | LLM inference | `agent_id`, `prompt`, `model` |
| `decision` | Conditional branch | `condition`, `condition_type` (contains/equals/regex/llm) |
| `action` | Execute action | `action_type`, `message`, `file_path`, `command`, `webhook_url`, `email_to`, `channel` |
| `approval` | Human gate | `timeout_minutes`, `approver`, `message` |

### Request/Response Examples

**POST `/v1/visual-workflows`**
```json
{
  "name": "Daily Report",
  "description": "Generate and email daily summary",
  "nodes": [
    {"id": "n1", "kind": "trigger", "label": "Every Morning", "positionX": 100, "positionY": 200,
     "config": {"trigger_type": "schedule", "cron_expression": "0 8 * * *"}},
    {"id": "n2", "kind": "agent", "label": "Generate Report", "positionX": 300, "positionY": 200,
     "config": {"agent_id": "sid", "prompt": "Generate a daily summary of all activity"}},
    {"id": "n3", "kind": "action", "label": "Send Email", "positionX": 500, "positionY": 200,
     "config": {"action_type": "sendEmail", "email_to": "team@example.com"}}
  ],
  "connections": [
    {"id": "c1", "fromNodeID": "n1", "toNodeID": "n2"},
    {"id": "c2", "fromNodeID": "n2", "toNodeID": "n3"}
  ]
}
```

**POST `/v1/visual-workflows/{id}/execute`**
```json
{
  "trigger": "manual",
  "data": {"override_prompt": "Focus on security events only"}
}
```

**Available Templates:**
1. `daily-summary` — Schedule → Agent → Email
2. `webhook-pipeline` — Webhook → Agent → Decision → Actions
3. `content-review` — Manual → Agent draft → Approval → Agent publish
4. `alert-responder` — Email → Agent classify → Decision → Actions
5. `team-handoff` — Trigger → Agent A → Approval → Agent B → Action

---

## 5. Cron Scheduler API — `/v1/cron/` & `/v1/schedules/`

**Files:** `CronSchedulerRoutes.swift`
**Purpose:** Scheduled task management with categories, retry, pause/resume, bulk operations.

### `/v1/cron/` — Task-Centric API

| # | Method | Path | Auth | Description |
|---|--------|------|------|-------------|
| 1 | GET | `/v1/cron/tasks` | chatOnly | List all scheduled tasks |
| 2 | GET | `/v1/cron/tasks/stats` | chatOnly | Scheduler statistics |
| 3 | POST | `/v1/cron/tasks` | execute | Create scheduled task |
| 4 | POST | `/v1/cron/validate` | chatOnly | Validate cron expression |
| 5 | GET | `/v1/cron/templates` | chatOnly | List available templates |
| 6 | POST | `/v1/cron/templates/{id}/create` | execute | Create task from template |
| 7 | GET | `/v1/cron/tasks/{id}` | chatOnly | Task detail |
| 8 | GET | `/v1/cron/tasks/{id}/history` | chatOnly | Execution history (`?limit=50`) |
| 9 | GET | `/v1/cron/tasks/{id}/next-runs` | chatOnly | Preview next runs (`?count=5`) |
| 10 | POST | `/v1/cron/tasks/{id}/run` | execute | Run immediately |
| 11 | POST | `/v1/cron/tasks/{id}/trigger` | execute | Alias for run |
| 12 | PUT | `/v1/cron/tasks/{id}` | execute | Update task |
| 13 | DELETE | `/v1/cron/tasks/{id}` | execute | Delete task |

### `/v1/schedules/` — Management API (New in Phase 6)

| # | Method | Path | Auth | Description |
|---|--------|------|------|-------------|
| 14 | GET | `/v1/schedules` | chatOnly | List all, grouped by category |
| 15 | GET | `/v1/schedules/categories` | chatOnly | List schedule categories |
| 16 | GET | `/v1/schedules/stats` | chatOnly | Full statistics |
| 17 | GET | `/v1/schedules/export` | chatOnly | Export all as JSON |
| 18 | POST | `/v1/schedules/import` | execute | Import from JSON (`?replace_existing=false`) |
| 19 | POST | `/v1/schedules/install-defaults` | execute | Install 6 default schedules |
| 20 | POST | `/v1/schedules/bulk/enable` | execute | Enable all |
| 21 | POST | `/v1/schedules/bulk/disable` | execute | Disable all |
| 22 | POST | `/v1/schedules/bulk/delete` | execute | Delete all |
| 23 | GET | `/v1/schedules/{id}` | chatOnly | Single schedule detail |
| 24 | PUT | `/v1/schedules/{id}` | execute | Update schedule |
| 25 | DELETE | `/v1/schedules/{id}` | execute | Delete schedule |
| 26 | POST | `/v1/schedules/{id}/clone` | execute | Clone schedule (`?name=New Name`) |
| 27 | POST | `/v1/schedules/{id}/pause` | execute | Pause (`?until=2026-03-01T00:00:00Z`) |
| 28 | POST | `/v1/schedules/{id}/resume` | execute | Resume paused schedule |
| 29 | DELETE | `/v1/schedules/{id}/history` | execute | Clear execution history |

### Request/Response Examples

**POST `/v1/cron/tasks`**
```json
{
  "name": "Morning Briefing",
  "cron_expression": "0 8 * * 1-5",
  "agent_id": "sid",
  "prompt": "Give me a morning briefing: weather, calendar, top news",
  "timezone": "America/New_York",
  "catch_up": false,
  "category": "reporting",
  "tags": ["daily", "briefing"],
  "max_retries": 2
}
```

**POST `/v1/cron/validate`**
```json
{
  "expression": "0 8 * * 1-5"
}
```
→ Response:
```json
{
  "valid": true,
  "description": "At 08:00 on Monday through Friday",
  "next_runs": [
    "2026-02-27T08:00:00-05:00",
    "2026-02-28T08:00:00-05:00",
    "2026-03-02T08:00:00-05:00"
  ]
}
```

**Cron Keywords:** `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`

**Default Templates:**
1. `memory-repair` — Daily at 2 AM: LoA dedup + compress + decay
2. `health-check` — Hourly: system health + service status
3. `security-audit` — Weekly Sunday at 3 AM: access log review + anomaly scan
4. `conversation-summary` — Daily at 11 PM: summarize day's conversations
5. `memory-cleanup` — Monthly 1st at 4 AM: deep memory maintenance
6. `morning-briefing` — Daily at 7:30 AM: weather + calendar + news

---

## Endpoint Count Summary

| API Group | Endpoints | New in Phase 6 |
|-----------|-----------|----------------|
| `/v1/governance/*` | 13 | 13 |
| `/v1/iam/*` | 12 | 12 |
| `/v1/teams/*` | 9 | 9 |
| `/v1/visual-workflows/*` | 10 | 10 |
| `/v1/cron/*` | 13 | 0 (existed, expanded) |
| `/v1/schedules/*` | 16 | 16 |
| **Web UIs** | 2 | 2 |
| **Phase 6 Total** | **75** | **62 new** |

### Web UI Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/governance` | Governance dashboard (HTML) |
| GET | `/workflow-designer` | Visual workflow designer (HTML) |

---

## Total API Surface (All Phases)

| Category | Endpoints |
|----------|-----------|
| Core Gateway | ~40 |
| Memory / LoA | ~30 |
| Governance | 13 |
| IAM | 12 |
| Teams | 9 |
| Visual Workflows | 10 |
| Cron / Schedules | 29 |
| Tasks | 7 |
| LifeOS | 6 |
| Commitments | 7 |
| Morning Briefing | 7 |
| WindDown | 7 |
| Cloud Auth / Billing | 9 |
| Home Automation | 5 |
| Skills | 4 |
| Events/SSE | 5 |
| **TOTAL** | **~200** |
