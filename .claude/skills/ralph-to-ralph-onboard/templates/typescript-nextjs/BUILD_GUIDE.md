# Build Guide: TypeScript + Next.js

## Framework
- Next.js 16 with App Router
- TypeScript strict mode, no `any` types
- Tailwind CSS for styling
- Radix UI recommended for components

## Project Structure
- `src/app/` — pages and layouts (App Router)
- `src/app/api/` — API routes
- `src/components/` — React components
- `src/lib/` — utilities, service clients
- `src/lib/db/` — Drizzle ORM schema and client
- `src/types/` — TypeScript types

## Auth Implementation
- API key mode: use Next.js middleware (`src/middleware.ts`)
- Better Auth mode: `npm install better-auth`, Drizzle adapter, Next.js middleware

## Testing
- Unit tests: Vitest with `@vitejs/plugin-react` (`tests/*.test.ts`)
- E2E tests: Playwright (`tests/e2e/*.spec.ts`)

## Commands
- `npm run dev` — dev server on port 3015
- `npm run build` — production build
- `npx tsc --noEmit` — typecheck
- `npx biome check .` — lint
