# Stack Profiles

Stack profiles describe the **architecture pattern** for the cloned product. Claude selects the best profile during onboarding based on research findings, then records it in `ralph-config.json` as `stackProfile`.

Profiles are **language-agnostic**: they describe process topology, data flow, and service boundaries. The concrete framework is determined by the `language` field + the matching template under `.claude/skills/ralph-to-ralph-onboard/templates/`. The same profile (e.g. `api-service`) produces a different scaffold for `typescript` vs `go` vs `python`, but the architecture shape is the same.

The build agent reads `stackProfile` to understand what to build — which services to wire up, how to separate processes, and which infrastructure patterns to follow.

---

## Profiles

### `api-service`

**Use when:** The target is primarily an API product (Resend, Twilio, Stripe, SendGrid, Mailgun, Postmark).

**Signals:**
- Core value is delivered via API calls, not a UI
- Has official SDKs in multiple languages
- Docs are API-reference heavy (endpoints, auth, rate limits)
- Product has a dashboard mainly for config/monitoring, not the core workflow
- Revenue model is typically usage-based (per email, per SMS, per API call)

**Architecture:**
```
API server                                    ← core product
  └─ Relational database (accounts, data model)
  └─ Redis / in-memory cache (rate limiting, queue state)
  └─ Job queue (for async delivery, webhook dispatch)
Frontend (dashboard + docs)
  └─ Calls the API server — never touches the DB directly
SDK package (packages/sdk/ or language equivalent)
```

**What this configures:**
- Separate API server process from the frontend
- Redis (or equivalent) for rate limiting and queue state
- Job queue for async operations (email delivery, webhook dispatch)
- SDK package scaffolded for at least the primary language
- API-key auth issued per user account (not session-based)

---

### `dashboard-app`

**Use when:** The target is primarily a web dashboard or SaaS tool (PostHog, Linear, Notion, Loom, Vercel dashboard).

**Signals:**
- Core value is the web UI — users spend most time in the app
- Has rich CRUD operations on a defined data model
- Auth is multi-user (team workspaces, orgs, roles)
- API exists but is secondary to the UI
- Data model is complex (lots of related tables)

**Architecture:**
```
Full-stack web app (single process)
  └─ Server-rendered UI + API routes colocated
  └─ Relational database (main data store)
  └─ Auth library (sessions, orgs, multi-user)
```

**What this configures:**
- Full-stack web framework with colocated API and UI
- Clear API layer for data operations
- Components organized by feature
- Multi-user auth (if `authMode: "better-auth"`)
- Schema matching the target product's data model

---

### `platform`

**Use when:** The target is infrastructure or a developer platform (Vercel, Railway, Fly.io, Render, Coolify, Supabase).

**Signals:**
- Manages compute, deployments, or infrastructure for other apps
- Has a control plane (API) + data plane (worker/agent) separation
- Uses webhooks heavily for async operations
- Billing model is often resource-based (CPU, memory, bandwidth)
- Has CLI tools alongside the web UI

**Architecture:**
```
Control plane (API + frontend, single process)
  └─ Manages projects, deployments, domains
  └─ Relational database (project/deployment state)
Worker plane (separate background process)
  └─ Executes deploys, health checks, scaling
  └─ Redis Pub/Sub or SQS for job coordination
CLI package (packages/cli/ or language equivalent)
```

**What this configures:**
- Separation between control plane and worker process
- Background worker for long-running operations
- Webhook ingestion and dispatch system
- CLI package scaffolded for the primary language
- Event-sourcing pattern for deployment state

---

### `content-app`

**Use when:** The target is content-focused (Ghost, Hashnode, Substack, Contentful, Sanity).

**Signals:**
- Core value is creating, editing, and publishing content
- Has a content editor (rich text, markdown, MDX)
- Content is often public-facing (SEO matters)
- Has content types/schemas with structured data
- May have a reader-facing site separate from the editor

**Architecture:**
```
Full-stack web app
  └─ Editor UI (rich text / markdown)
  └─ Reader-facing routes (ISR/SSG or equivalent caching)
  └─ Relational database (content model + authors)
  └─ CDN-friendly caching for public pages
  └─ Image optimization + object storage
```

**What this configures:**
- Static/incremental rendering for public content pages
- Separate editor and reader routes
- Content schema (posts, authors, tags, revisions)
- Object storage (S3 / R2 / equivalent)
- CDN headers and caching strategy
- RSS/Atom feed generation

---

### `realtime-app`

**Use when:** The target has real-time collaborative or live features (Figma, Liveblocks, Pusher, Socket.io-based apps, Ably).

**Signals:**
- Multi-user collaboration or live updates
- WebSocket or SSE connections central to the product
- Presence awareness (who else is online/in the doc)
- Operational transforms or CRDT-like data sync
- Low-latency event delivery is a core requirement

**Architecture:**
```
WebSocket server (separate from HTTP server)
  └─ Manages rooms, presence, event broadcast
  └─ Redis Pub/Sub (scale across WS instances)
Frontend
  └─ Connects to WS server via client library
  └─ Optimistic UI updates with server reconciliation
Relational database (persistent state, snapshots)
Event bus for async side effects
```

**What this configures:**
- Dedicated WebSocket server process
- Redis for Pub/Sub across WS instances
- Client-side WebSocket connection layer
- Presence and room management
- Conflict-resolution strategy (last-write-wins or CRDT)
- Snapshot persistence pattern

---

## How to choose

Claude selects `stackProfile` in Step 3 of onboarding based on these signals:

| If the product's primary value is... | Use profile |
|--------------------------------------|-------------|
| Sending data via API (email, SMS, payments) | `api-service` |
| A web dashboard users work in daily | `dashboard-app` |
| Managing infrastructure for other apps | `platform` |
| Creating and publishing content | `content-app` |
| Real-time collaboration or live data | `realtime-app` |

When unsure, default to `dashboard-app` — it's the most flexible and covers the majority of SaaS products.

---

## ralph-config.json field

```json
{
  "language": "typescript",
  "stackProfile": "dashboard-app"
}
```

Valid values: `"api-service"`, `"dashboard-app"`, `"platform"`, `"content-app"`, `"realtime-app"`

The build agent reads this field (together with `language`) to determine:
- Which template to apply via `setup-stack.sh`
- How many processes to run (single vs control+worker vs HTTP+WS)
- Which dependencies to install (Redis, job queue, SDK, CLI, etc.)
- Which infrastructure patterns to follow in `scripts/preflight.sh`
