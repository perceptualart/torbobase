# LoA Memory Engine

**Library of Alexandria Memory Engine** — a persistent, structured knowledge store that gives all Torbo agents a shared, evolving understanding of the user.

## Overview

The Memory Engine is separate from the existing vector-based MemoryIndex. While MemoryIndex stores unstructured text with embeddings for semantic search, the Memory Engine stores **typed, queryable records** organized into five core tables. It includes automatic confidence decay, time-sensitive fact expiration, and a background distillation job that extracts knowledge from conversations.

**Database:** SQLite (`loa.db` in the Base data directory)
**Routes:** Mounted at `/memory`
**Distillation:** Runs every 15 minutes, extracts knowledge from conversation history

---

## Schema

### facts
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key, auto-increment |
| category | TEXT | e.g. preference, biographical, work, technical, health, financial |
| key | TEXT | Short identifier (e.g. "favorite_color", "job_title") |
| value | TEXT | The fact itself |
| confidence | REAL | 0.0-1.0, decays over time without reinforcement |
| source | TEXT | Origin: "user", "api", "distillation" |
| created_at | TEXT | ISO 8601 |
| updated_at | TEXT | ISO 8601 (refreshed on reinforcement) |
| expires_at | TEXT | ISO 8601, nullable (for time-sensitive facts) |

Unique constraint: `(category, key)` — same category+key updates instead of duplicating.

### people
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| name | TEXT | Unique, case-insensitive |
| relationship | TEXT | e.g. "friend", "coworker" |
| last_contact | TEXT | ISO 8601 or description |
| sentiment | TEXT | positive / negative / neutral |
| notes | TEXT | Free-form |
| updated_at | TEXT | ISO 8601 |

### patterns
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| pattern_type | TEXT | habit, schedule, preference, communication |
| description | TEXT | What the pattern is |
| frequency | INTEGER | Times observed |
| last_observed | TEXT | ISO 8601 |
| confidence | REAL | 0.0-1.0, increases with observation |

### open_loops
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| topic | TEXT | What the open item is |
| first_mentioned | TEXT | ISO 8601 |
| mention_count | INTEGER | Times topic came up |
| last_mentioned | TEXT | ISO 8601 |
| resolved | INTEGER | 0 = open, 1 = resolved |
| priority | INTEGER | 0-5, higher = urgent |

### signals
| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Primary key |
| signal_type | TEXT | stress, energy, mood, sleep, health |
| value | TEXT | Description |
| observed_at | TEXT | ISO 8601 |

---

## REST API

All endpoints mounted at `/memory`, require authentication.

| Method | Path | Description |
|--------|------|-------------|
| POST | /memory/fact | Write a fact (category, key, value, confidence, source, expires_at) |
| GET | /memory/context?topic=X | Fuzzy search across all tables, ranked results |
| GET | /memory/person/:name | Full profile for a contact |
| POST | /memory/person | Upsert a person (name, relationship, sentiment, notes) |
| GET | /memory/open-loops | All unresolved open loops (priority + mention count) |
| POST | /memory/open-loop | Create/update an open loop (topic, priority) |
| POST | /memory/open-loop/:id/resolve | Mark an open loop as resolved |
| POST | /memory/signal | Log a behavioral signal (signal_type, value) |
| GET | /memory/patterns | All patterns sorted by confidence |
| POST | /memory/pattern | Create/update a pattern (pattern_type, description, confidence) |
| GET | /memory/health | Engine status + record counts per category |

### Example: Write a fact
```bash
curl -X POST http://localhost:4200/memory/fact \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"category":"preference","key":"coffee_order","value":"Oat milk latte","confidence":0.9}'
```

### Example: Search context
```bash
curl "http://localhost:4200/memory/context?topic=coffee" \
  -H "Authorization: Bearer TOKEN"
```

### Example: Log a signal
```bash
curl -X POST http://localhost:4200/memory/signal \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"signal_type":"mood","value":"Upbeat, excited about new project"}'
```

---

## Distillation

Runs every 15 minutes:
1. Reads new conversation turns from ConversationStore
2. Sends to local LLM (qwen2.5:7b via Ollama) with structured extraction prompt
3. Extracts: facts, people, patterns, open items, signals
4. Writes to LoA with `source: "distillation"` and appropriate confidence
5. Deduplicates via category+key upsert
6. Runs decay cycle after each distillation

Starts 2 minutes after boot, repeats every 15 minutes.

---

## Decay System

- Facts older than **90 days** without reinforcement: confidence decays **10% per week**
- Facts with confidence below **0.2**: archived (kept but excluded from searches)
- Time-sensitive facts with `expires_at`: auto-expired when deadline passes
- Reinforcement (re-writing same category+key) refreshes `updated_at` and resets decay

---

## Integration Guide

### Best Practices
1. Use specific `category`+`key` pairs — not generic identifiers
2. Set confidence: 0.9+ explicit, 0.5-0.7 inferred, 0.3-0.5 uncertain
3. Include `source` for provenance tracking
4. Don't duplicate distillation — it already extracts from conversations
5. Check `GET /memory/health` to confirm engine is running

### Files
- `Sources/TorboBase/Gateway/Memory/LoAMemoryEngine.swift` — Core actor, SQLite, CRUD, decay
- `Sources/TorboBase/Gateway/Memory/LoAMemoryRoutes.swift` — REST API routes
- `Sources/TorboBase/Gateway/Memory/LoADistillation.swift` — Background extraction job
