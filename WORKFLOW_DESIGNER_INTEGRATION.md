# Visual Workflow Designer — Integration Guide

## Overview

The Visual Workflow Designer adds a drag-and-drop workflow builder to Torbo Base. Users can create complex automations by connecting nodes on a visual canvas — no code required.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Visual Workflow Designer                   │
├─────────────┬───────────────┬───────────────────────────────┤
│  SwiftUI UI │   Web UI      │   REST API                    │
│  (macOS)    │   (Linux/Web) │   /v1/visual-workflows/*      │
├─────────────┴───────────────┴───────────────────────────────┤
│                 WorkflowExecutor (actor)                      │
│  Graph traversal · Decision branching · Approval gates       │
├──────────────────────────────────────────────────────────────┤
│              WorkflowIntegrationManager (actor)              │
│  CronScheduler · WebhookManager · TelegramBridge · Email     │
├──────────────────────────────────────────────────────────────┤
│              Existing Torbo Base Infrastructure               │
│  TaskQueue · ProactiveAgent · AgentConfig · EventBus         │
└──────────────────────────────────────────────────────────────┘
```

## New Files

| File | Location | Purpose |
|------|----------|---------|
| `WorkflowModels.swift` | `Gateway/` | Data model: VisualWorkflow, VisualNode, NodeConnection, NodeConfig, execution models, VisualWorkflowStore |
| `WorkflowExecutor.swift` | `Gateway/` | Actor-based graph execution engine with decision branching, approval gates, parallel paths |
| `WorkflowTemplates.swift` | `Gateway/` | 5 pre-built workflow templates |
| `WorkflowRoutes.swift` | `Gateway/` | REST API route handler (10 endpoints) |
| `WorkflowIntegration.swift` | `Gateway/` | Hooks triggers into CronScheduler, WebhookManager, TelegramBridge, EmailBridge, FileVault |
| `WorkflowDesignerHTML.swift` | `Gateway/` | Self-contained HTML/CSS/JS web UI for Linux |
| `WorkflowCanvasView.swift` | `Views/` | SwiftUI drag-and-drop canvas with zoom/pan |
| `WorkflowNodeEditors.swift` | `Views/` | Sheet-based node configuration editors |

## How to Wire Into GatewayServer

Add these route handlers to the main switch statement in `GatewayServer.swift`:

```swift
// Visual Workflow Designer routes
case let (method, path) where path.hasPrefix("/v1/visual-workflows"):
    if let result = await WorkflowDesignerRoutes.handle(
        method: method, path: path, body: req.body,
        queryParams: req.queryParams
    ) {
        return HTTPResponse(statusCode: result.statusCode,
                           headers: ["Content-Type": result.contentType],
                           body: result.responseData())
    }
    return HTTPResponse(statusCode: 404, body: "Not found".data(using: .utf8)!)

// Workflow Designer web UI
case ("GET", "/workflow-designer"):
    let html = WorkflowDesignerHTML.page()
    return HTTPResponse(statusCode: 200,
                       headers: ["Content-Type": "text/html"],
                       body: html.data(using: .utf8)!)
```

## How to Wire Into DashboardView

Add a workflow tab to `DashboardTab` enum in `AppState.swift`:

```swift
case workflows = "Workflows"

// In the icon computed property:
case .workflows: return "point.3.connected.trianglepath.dotted"

// In the hint computed property:
case .workflows: return "Visual workflow builder"
```

Then in `DashboardView.swift`, add the case to the detail content switch:

```swift
case .workflows:
    WorkflowCanvasView()
```

## How to Start Trigger Registration

In your startup sequence (e.g., `LinuxMain.swift` or `TorboBaseApp.swift`):

```swift
// After other subsystems are initialized
Task {
    await WorkflowIntegrationManager.shared.registerAllTriggers()
}
```

And in your shutdown handler:

```swift
await WorkflowIntegrationManager.shared.shutdown()
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/v1/visual-workflows` | List all workflows |
| `POST` | `/v1/visual-workflows` | Create workflow (`{ "name": "..." }`) |
| `GET` | `/v1/visual-workflows/{id}` | Get full workflow with nodes/connections |
| `PUT` | `/v1/visual-workflows/{id}` | Update workflow (full or partial) |
| `DELETE` | `/v1/visual-workflows/{id}` | Delete workflow |
| `POST` | `/v1/visual-workflows/{id}/execute` | Execute workflow manually |
| `GET` | `/v1/visual-workflows/{id}/executions` | Get execution history |
| `POST` | `/v1/visual-workflows/{id}/approve/{execID}` | Approve/deny pending execution |
| `GET` | `/v1/visual-workflows/templates` | List available templates |
| `POST` | `/v1/visual-workflows/from-template/{name}` | Create from template |

## Node Types

### Trigger
Starts the workflow. Types: Schedule (cron), Webhook, Telegram keyword, Email filter, File change, Manual.

### Agent
Processes data through an AI agent (SiD, Orion, Mira, aDa, or custom). Supports prompt override with `{{context}}` and `{{result}}` template variables.

### Decision
Conditional branching. Evaluates expressions like `contains('urgent')`, `equals('yes')`, `length > 100`, `not_empty`. Routes to true/false paths.

### Action
Performs an action: Send message (Telegram/Discord/Slack), Write file, Run command, Call webhook, Send email, Broadcast to channel.

### Approval
Pauses execution until a human approves via API. Configurable timeout with auto-deny.

## Data Storage

- Workflows: `~/Library/Application Support/TorboBase/visual_workflows.json`
- Execution history: `~/Library/Application Support/TorboBase/workflow_executions.json`
- Uses ISO 8601 dates, pretty-printed JSON with sorted keys
- History capped at 500 entries

## Templates

1. **Email Triage** — Email → Classify → If urgent → Alert → Else → Auto-reply
2. **Meeting Prep** — Schedule → Research → Briefing → Send to Telegram
3. **Invoice Processing** — File change → Extract data → Approval → Save CSV
4. **Price Monitor** — Hourly → Check price → If changed >5% → Alert
5. **Daily Summary** — 6pm daily → Summarize → Email report

## Execution Model

1. Executor starts from trigger nodes
2. Traverses the graph depth-first
3. Decision nodes evaluate conditions and route to true/false branches
4. Parallel paths execute concurrently via Swift TaskGroup
5. Approval nodes suspend execution until API approval
6. Agent nodes create TaskQueue tasks executed by ProactiveAgent
7. Context flows through nodes via `execution.context` dictionary
8. Execution history persisted to disk on completion

## Security

- Action nodes respect existing access level checks
- File writes use expanded paths (no path traversal)
- Command execution goes through shell — restricted by OS permissions
- Webhook calls use URLSession with 30s timeout
- Approval gates prevent automated execution of sensitive actions
