# Future Cloud Provider Support

Cloud providers to add beyond the current AWS / GCP / Azure options. Each must have a CLI that can provision infrastructure programmatically (database, storage, container deployment).

## Candidates

### DigitalOcean
- **CLI:** `doctl` — [install](https://docs.digitalocean.com/reference/doctl/how-to/install/)
- **Database:** Managed Postgres (`doctl databases create`)
- **Storage:** Spaces (S3-compatible, `doctl spaces`)
- **Deploy:** App Platform (`doctl apps create`) or container registry + Kubernetes
- **Auth check:** `doctl account get`
- **Why:** Popular with indie devs, simple pricing, good CLI

### Vercel
- **CLI:** `vercel` — `npm i -g vercel`
- **Database:** Vercel Postgres (powered by Neon) or bring your own
- **Storage:** Vercel Blob (`@vercel/blob`)
- **Deploy:** `vercel deploy` — zero-config for Next.js
- **Auth check:** `vercel whoami`
- **Why:** Native Next.js deployment, zero-config, great DX. Best option for users who just want to ship fast without managing infra.
- **Note:** Vercel handles deployment but not all infra (email, queues). May need to pair with external services.

### Railway
- **CLI:** `railway` — `npm i -g @railway/cli`
- **Database:** Managed Postgres (`railway add --plugin postgresql`)
- **Storage:** No native object storage (use S3/Cloudflare R2)
- **Deploy:** `railway up` — Dockerfile or Nixpacks auto-detect
- **Auth check:** `railway whoami`
- **Why:** Simple deploy, good Postgres support, popular with Next.js devs

### Fly.io
- **CLI:** `flyctl` — [install](https://fly.io/docs/flyctl/install/)
- **Database:** Fly Postgres (managed) or LiteFS for SQLite
- **Storage:** Tigris (S3-compatible, `fly storage create`)
- **Deploy:** `fly deploy` — Dockerfile-based
- **Auth check:** `fly auth whoami`
- **Why:** Edge deployment, good for latency-sensitive apps

### Cloudflare
- **CLI:** `wrangler` — `npm i -g wrangler`
- **Database:** D1 (SQLite-based) or Hyperdrive (Postgres proxy)
- **Storage:** R2 (S3-compatible)
- **Deploy:** Cloudflare Pages or Workers
- **Auth check:** `wrangler whoami`
- **Why:** Edge-first, great for static + API, R2 is free egress
- **Note:** D1 is SQLite not Postgres — would need Drizzle adapter changes or use Hyperdrive

## Implementation Pattern

For each new provider, you need:
1. Add the option to `ralph/onboard.sh` cloud provider menu
2. Add CLI + auth checks to `ralph/onboard-prompt.md` Step 6
3. Add a preflight template to `ralph/onboard-prompt.md` (Preflight Script Templates section)
4. Add package.json dependencies per provider to `ralph/onboard-prompt.md` Step 7c
5. Add the cloud name to the validation in `ralph/onboard.sh` (`python3 -c` schema check)
6. Test end-to-end

## Priority Order

1. **Vercel** — most natural for Next.js, largest user overlap
2. **DigitalOcean** — simple, popular, full CLI
3. **Railway** — great DX, popular with indie hackers
4. **Fly.io** — good for edge deployment use cases
5. **Cloudflare** — powerful but SQLite default requires more changes
