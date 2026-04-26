# Feature Structure: Authentication (auth-001)

## Phase 1: Database and Backend Setup
- **Summary:** Better Auth configured with Drizzle and a basic login API.
- **Scope:** DB Schema + Auth Config + API Route.
- **Key Changes:** `src/lib/db/schema.ts`, `src/lib/auth.ts`, `src/app/api/auth/[...all]/route.ts`.
- **Verification:** `make test` (verify auth client initializes) + `curl /api/auth/session`.
- **Done:** [ ]

## Phase 2: Login/Signup UI
- **Summary:** User can create an account and log in with email/password.
- **Scope:** Auth Pages + Form Logic.
- **Key Changes:** `src/app/(auth)/login/page.tsx`, `src/app/(auth)/signup/page.tsx`.
- **Verification:** `make test-e2e` (smoke test login flow).
- **Done:** [ ]

## Phase 3: Middleware and Protected Routes
- **Summary:** Authenticated users only can access the dashboard.
- **Scope:** Middleware + Layout Protection.
- **Key Changes:** `src/middleware.ts`, `src/app/layout.tsx`.
- **Verification:** `make test-e2e` (verify redirect to /login for unauth users).
- **Done:** [ ]
