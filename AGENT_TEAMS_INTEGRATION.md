# Agent Teams — Integration Guide

## Overview

Agent Teams enables multiple agents to work in parallel on different parts of a complex task and coordinate their results. A **coordinator agent** decomposes tasks into subtasks, assigns them to **specialist agents**, executes them in parallel (respecting dependencies), and aggregates the results.

## Architecture

```
User Request
    │
    ▼
TeamCoordinator (actor)
    │
    ├── 1. Decompose ──► Coordinator Agent (LLM call)
    │                         │
    │                         ▼
    │                    [Subtask 1, Subtask 2, Subtask 3]
    │
    ├── 2. Assign ────► Round-robin to specialist agents
    │
    ├── 3. Execute ───► ParallelExecutor / TaskGroup
    │                    ├── Subtask 1 (agent A) ──► Gateway ──► LLM
    │                    ├── Subtask 2 (agent B) ──► Gateway ──► LLM  (parallel)
    │                    └── Subtask 3 (agent A) ──► waits on 1,2 ──► Gateway ──► LLM
    │
    └── 4. Aggregate ─► Coordinator Agent (LLM call)
                              │
                              ▼
                         Final Result
```

## Files

| File | Purpose |
|------|---------|
| `AgentTeam.swift` | Data models: AgentTeam, TeamTask, Subtask, TeamResult, TeamExecution, TeamSharedContext |
| `TeamCoordinator.swift` | Core orchestration actor — decomposition, execution, aggregation |
| `TaskQueueTeamIntegration.swift` | Bridge between TaskQueue/ProactiveAgent and TeamCoordinator |
| `AgentTeamsRoutes.swift` | HTTP API route handlers (extension on GatewayServer) |
| `AgentTeamsView.swift` | SwiftUI management UI |
| `DefaultTeams.swift` | Pre-configured team templates |

## Integration Steps

### 1. Register API Routes in GatewayServer.swift

Add these cases to the main `switch (req.method, req.path)` block in `GatewayServer.route()`, after the Workflow routes section:

```swift
// --- Agent Teams Routes ---
case ("GET", "/v1/teams"):
    return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
        await self.handleTeamsList(req)
    }
case ("POST", "/v1/teams"):
    return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
        await self.handleTeamsCreate(req)
    }
case _ where req.path.hasPrefix("/v1/teams/") && req.path.hasSuffix("/execute") && req.method == "POST":
    return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
        await self.handleTeamsExecute(req)
    }
case _ where req.path.hasPrefix("/v1/teams/") && req.path.hasSuffix("/executions") && req.method == "GET":
    return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
        await self.handleTeamsExecutionHistory(req)
    }
case _ where req.path.hasPrefix("/v1/teams/") && req.path.hasSuffix("/context") && req.method == "GET":
    return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
        await self.handleTeamsGetContext(req)
    }
case _ where req.path.hasPrefix("/v1/teams/") && req.path.hasSuffix("/context") && req.method == "PUT":
    return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
        await self.handleTeamsUpdateContext(req)
    }
case _ where req.path.hasPrefix("/v1/teams/") && req.method == "GET":
    return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
        await self.handleTeamsGet(req)
    }
case _ where req.path.hasPrefix("/v1/teams/") && req.method == "PUT":
    return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
        await self.handleTeamsUpdate(req)
    }
case _ where req.path.hasPrefix("/v1/teams/") && req.method == "DELETE":
    return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
        await self.handleTeamsDelete(req)
    }
```

**Important:** Place the more specific routes (with `/execute`, `/executions`, `/context` suffixes) BEFORE the generic `GET /v1/teams/{id}` route to ensure correct matching.

### 2. Install Default Teams on Startup

In your app startup sequence (e.g., `TorboBaseApp.swift` or wherever `ProactiveAgent.shared.start()` is called), add:

```swift
Task { await DefaultTeams.installIfNeeded() }
```

### 3. Add Teams Tab to Dashboard (Optional)

In `DashboardView.swift`, add a new tab case and link to `AgentTeamsView()`:

```swift
case .teams:
    AgentTeamsView()
```

### 4. Enable ProactiveAgent Team Routing (Optional)

To automatically route tasks to teams when detected, modify `ProactiveAgent.executeTask()` to check `TeamTaskRouter` first:

```swift
private func executeTask(_ task: TaskQueue.AgentTask, agentID: String) async {
    // Check if this task should be handled by a team
    if let teamResult = await TeamTaskRouter.shared.interceptForTeam(task: task) {
        await TaskQueue.shared.completeTask(id: task.id, result: teamResult)
        return
    }
    // ... existing execution logic ...
}
```

## API Reference

### Teams CRUD

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/teams` | List all teams |
| POST | `/v1/teams` | Create a team |
| GET | `/v1/teams/{id}` | Get team details |
| PUT | `/v1/teams/{id}` | Update a team |
| DELETE | `/v1/teams/{id}` | Delete a team |

### Team Execution

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/teams/{id}/execute` | Execute a task with the team |
| GET | `/v1/teams/{id}/executions` | Get execution history |

### Shared Context

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/teams/{id}/context` | Get shared context |
| PUT | `/v1/teams/{id}/context` | Update shared context |

### Example: Create a Team

```bash
curl -X POST http://localhost:4200/v1/teams \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "My Research Team",
    "coordinator": "sid",
    "members": ["orion", "mira"],
    "description": "Custom research team"
  }'
```

### Example: Execute a Team Task

```bash
curl -X POST http://localhost:4200/v1/teams/TEAM_ID/execute \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Research the latest trends in AI agent frameworks and write a summary report"
  }'
```

### Example: Update Shared Context

```bash
curl -X PUT http://localhost:4200/v1/teams/TEAM_ID/context \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "entries": {
      "project_name": "Torbo",
      "target_audience": "developers"
    }
  }'
```

## How It Works

### Task Decomposition

The coordinator agent receives a prompt asking it to break the task into subtasks. It returns a JSON array of subtasks with:
- `description` — what to do
- `assigned_to` — which agent handles it
- `depends_on` — indices of subtasks that must complete first

The coordinator maximizes parallelism — only adding dependencies when outputs are truly needed as inputs.

### Dependency Resolution

Subtasks execute in waves:
1. All subtasks with no dependencies run in parallel (Wave 1)
2. Once Wave 1 completes, subtasks that depended on Wave 1 become ready (Wave 2)
3. Repeat until all subtasks are done

If a subtask fails, dependent subtasks still run but receive partial context.

### Shared Context

Teams have a key-value shared context that persists across executions. Agents can read shared context during execution to access team-level configuration, ongoing state, or accumulated knowledge.

### Result Aggregation

After all subtasks complete, the coordinator receives all results and synthesizes them into a single coherent response. The coordinator resolves conflicts and presents the output as a unified answer.

## Persistence

- Teams: `~/Library/Application Support/TorboBase/agent_teams.json`
- Execution history: `~/Library/Application Support/TorboBase/agent_teams_history.json`
- History is capped at 200 entries (FIFO)
