# Cron Scheduler Integration Guide

## Architecture Overview

```
CronScheduler (actor)
    ├── CronExpression (parser)
    ├── CronParser (utilities)
    │   ├── Keyword resolution (@hourly → 0 * * * *)
    │   ├── Validation with error messages
    │   ├── Human-readable descriptions
    │   └── Next-N-runs preview
    ├── CronTaskIntegration (actor)
    │   ├── Bridges to TaskQueue
    │   ├── Records execution history
    │   └── Missed execution recovery
    ├── CronTemplates (static)
    │   └── Pre-built schedule templates
    └── CronSchedulerRoutes (HTTP API)
        └── Full REST API for CRUD + operations
```

## Data Flow

```
Schedule fires (CronScheduler loop, every 60s)
  → CronTaskIntegration.executeScheduledTask()
    → TaskQueue.shared.createTask() (creates AgentTask)
      → ProactiveAgent picks up task
        → Executes through LLM pipeline
      → Result written to TaskQueue
    → CronTaskIntegration polls for completion
  → CronScheduler.recordExecution() (history)
  → EventBus publishes system.cron.fired / system.cron.error
  → ConversationStore.appendMessage() (iOS client)
```

## Cron Expression Format

Standard 5-field: `minute hour day-of-month month day-of-week`

| Field       | Values  | Special Characters |
|-------------|---------|-------------------|
| Minute      | 0-59    | * , - /           |
| Hour        | 0-23    | * , - /           |
| Day (month) | 1-31    | * , - /           |
| Month       | 1-12    | * , - /           |
| Day (week)  | 0-6     | * , - / (0=Sun, named: MON-SUN) |

### Special Keywords

| Keyword    | Equivalent      | Description     |
|------------|----------------|-----------------|
| @yearly    | 0 0 1 1 *      | January 1, midnight |
| @annually  | 0 0 1 1 *      | Same as @yearly |
| @monthly   | 0 0 1 * *      | 1st of month, midnight |
| @weekly    | 0 0 * * 0      | Sunday midnight |
| @daily     | 0 0 * * *      | Every midnight  |
| @midnight  | 0 0 * * *      | Same as @daily  |
| @hourly    | 0 * * * *      | Top of every hour |

### Examples

| Expression      | Description                    |
|----------------|-------------------------------|
| `*/5 * * * *`  | Every 5 minutes               |
| `0 */2 * * *`  | Every 2 hours                 |
| `0 8 * * *`    | Daily at 8:00 AM              |
| `0 9 * * 1-5`  | Weekdays at 9:00 AM           |
| `0 9 * * 1`    | Every Monday at 9:00 AM       |
| `0 0 1 * *`    | Monthly on the 1st at midnight|
| `30 8 * * MON` | Every Monday at 8:30 AM       |

## REST API

Base path: `/v1/cron/`

### Schedules CRUD

| Method | Path                          | Description               |
|--------|-------------------------------|---------------------------|
| GET    | /v1/cron/tasks                | List all schedules        |
| POST   | /v1/cron/tasks                | Create schedule           |
| GET    | /v1/cron/tasks/{id}           | Get schedule details      |
| PUT    | /v1/cron/tasks/{id}           | Update schedule           |
| DELETE | /v1/cron/tasks/{id}           | Delete schedule           |
| GET    | /v1/cron/tasks/stats          | Scheduler statistics      |

### Operations

| Method | Path                          | Description               |
|--------|-------------------------------|---------------------------|
| POST   | /v1/cron/tasks/{id}/run       | Run immediately           |
| POST   | /v1/cron/tasks/{id}/trigger   | Run immediately (alias)   |
| GET    | /v1/cron/tasks/{id}/history   | Execution history         |
| GET    | /v1/cron/tasks/{id}/next-runs | Preview next executions   |
| POST   | /v1/cron/validate             | Validate expression       |

### Templates

| Method | Path                              | Description             |
|--------|-----------------------------------|-------------------------|
| GET    | /v1/cron/templates                | List all templates      |
| POST   | /v1/cron/templates/{id}/create    | Create from template    |

### Create Schedule

```bash
curl -X POST http://localhost:4200/v1/cron/tasks \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -d '{
    "name": "Morning Briefing",
    "cron_expression": "0 8 * * *",
    "prompt": "Prepare my morning briefing with calendar, weather, and news",
    "agent_id": "sid",
    "timezone": "America/New_York",
    "catch_up": true
  }'
```

### Validate Expression

```bash
curl -X POST http://localhost:4200/v1/cron/validate \
  -H "Content-Type: application/json" \
  -d '{"expression": "*/5 * * * *"}'
```

Response:
```json
{
  "valid": true,
  "expression": "*/5 * * * *",
  "description": "Every 5 minutes",
  "next_runs": ["2026-02-26T12:05:00Z", "2026-02-26T12:10:00Z", ...]
}
```

## Swift API

### Creating a Schedule

```swift
let task = await CronScheduler.shared.createTask(
    name: "Price Check",
    cronExpression: "@hourly",
    agentID: "sid",
    prompt: "Check current BTC and ETH prices",
    timezone: "UTC",
    catchUp: false
)
```

### Using Templates

```swift
let task = await CronTaskIntegration.shared.createFromTemplate(
    CronTemplates.morningBriefing,
    agentID: "custom_agent"
)
```

### Parsing & Validation

```swift
let result = CronParser.validate("*/5 * * * *")
// result.isValid = true
// result.description = "Every 5 minutes"

let runs = CronParser.nextRuns("0 8 * * 1-5", count: 5)
// [Mon 8AM, Tue 8AM, Wed 8AM, Thu 8AM, Fri 8AM]
```

## Execution History

Each schedule keeps the last 50 executions, recording:
- Timestamp
- Success/failure
- Duration (seconds)
- Result text (truncated to 500 chars)
- Error message (if failed)

Access via API: `GET /v1/cron/tasks/{id}/history?limit=20`

Access in Swift: `schedule.executionLog`

## Missed Execution Recovery

On startup, the scheduler:
1. Checks all enabled schedules for missed executions (up to 24h back)
2. For schedules with `catchUp: true` (default), runs the task once to catch up
3. For schedules with `catchUp: false`, logs the miss and skips

Configure per schedule:
```json
{"catch_up": false}
```

## SwiftUI Dashboard

`CronSchedulerView` provides a full management interface:
- Schedule list with status indicators and enable/disable toggles
- Detail panel with expression, task info, stats, and execution history
- Create sheet with visual pattern selector and expression validator
- Template sheet for quick setup from pre-built templates
- Context menu with run-now, toggle, and delete actions

### Integration

Add to your view hierarchy:
```swift
CronSchedulerView()
    .environmentObject(appState)
```

## Files

| File | Description |
|------|-------------|
| `Gateway/CronScheduler.swift` | Core scheduler actor, CronTask model, CronExpression parser |
| `Gateway/CronParser.swift` | Keyword resolution, validation, descriptions, preview |
| `Gateway/CronSchedulerRoutes.swift` | REST API endpoints |
| `Gateway/CronTaskIntegration.swift` | TaskQueue/ProactiveAgent bridge |
| `Gateway/CronTemplates.swift` | Pre-built schedule templates |
| `Views/CronSchedulerView.swift` | SwiftUI dashboard (macOS) |
