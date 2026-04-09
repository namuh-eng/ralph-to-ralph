# Stack Profiles

Stack profiles describe the architecture pattern for the cloned product. Claude selects the best profile during onboarding based on research findings, then records it in `ralph-config.json` as `stackProfile`.

The build agent reads `stackProfile` to understand what to build — which services to wire up, how to structure the API layer, and which infrastructure patterns to follow.

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
API Server (Express/Fastify on Node)   ← core product
  └─ Postgres (data model, accounts)
  └─ Redis (rate limiting, job queues)
  └─ Job queue (BullMQ / SQS) for async delivery
Next.js frontend (dashboard + docs)
  └─ Calls the API server (not directly to DB)
TypeScript SDK package (packages/sdk/)
```

**What this configures:**
- Separate API server entry point (`src/server/`)
- Next.js frontend that proxies to the API layer
- Redis for rate limiting and queue state
- Job queue for async operations (email delivery, webhook dispatch)
- SDK package scaffolded under `packages/sdk/`
- API key auth (issued per user account, not Better Auth sessions)

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
Next.js App Router (full-stack)
  └─ src/app/api/ — API routes (server actions or REST)
  └─ src/components/ — rich UI components
  └─ Postgres (main data store)
  └─ Auth (Better Auth with Drizzle adapter)
```

**What this configures:**
- Next.js full-stack with API routes inside the app
- Clear API layer separation (`src/app/api/` handles all data ops)
- Components organized by feature (not by type)
- Better Auth for multi-user auth
- Drizzle schema matching the target product's data model

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
Control plane (Next.js API + frontend)
  └─ Manages projects, deployments, domains
  └─ Postgres (project/deployment state)
Worker plane (background service)
  └─ Executes deploys, health checks, scaling
  └─ Redis / SQS for job coordination
CLI package (packages/cli/)
```

**What this configures:**
- Separation between control plane (Next.js) and worker/agent service
- Background worker for long-running operations
- Webhook ingestion and dispatch system
- CLI package scaffolded under `packages/cli/`
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
Next.js App Router
  └─ Editor UI (rich text / markdown)
  └─ Reader-facing site (SSG/ISR for SEO)
  └─ Postgres (content model + authors)
  └─ CDN-friendly API (static generation)
  └─ Image optimization + storage
```

**What this configures:**
- Next.js with ISR/SSG for public content pages
- Separate editor and reader routes
- Content schema in Drizzle (posts, authors, tags, revisions)
- Image storage (S3/Cloudflare R2/Neon Blobs)
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
WebSocket server (separate from Next.js HTTP server)
  └─ Manages rooms, presence, event broadcast
  └─ Redis Pub/Sub (scale across WS server instances)
Next.js frontend
  └─ Connects to WS server via client library
  └─ Optimistic UI updates with server reconciliation
Postgres (persistent state, snapshots)
Event bus for async side effects
```

**What this configures:**
- Dedicated WebSocket server (`src/ws-server/`)
- Redis for Pub/Sub across WS instances
- Client-side WebSocket hook/provider
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
  "stackProfile": "dashboard-app"
}
```

Valid values: `"api-service"`, `"dashboard-app"`, `"platform"`, `"content-app"`, `"realtime-app"`

The build agent reads this field to determine:
- Which services to initialize
- How to structure `src/`
- Which dependencies to install
- Which infrastructure patterns to follow in `scripts/preflight.sh`
