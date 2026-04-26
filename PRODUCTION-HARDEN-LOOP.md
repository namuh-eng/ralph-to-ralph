# PRODUCTION-HARDEN-LOOP.md — Design Spec

_From MVP to Production-Grade SaaS._

## Overview

The **Production Harden Loop** (Phases 4-8) is the post-parity hardening engine. It takes a working clone produced by the **Build Loop** (Phases 1-3) and upgrades it until it meets professional engineering standards for security, performance, observability, and operational reliability.

## The Phases

### Phase 4: AUDIT (Discovery)
- **Input:** Source tree, `prd.json`, `qa-report.json`, `ralph-config.json`.
- **Action:** Parallel auditor agents scan for gaps.
- **Auditors:**
  - `feature-parity-auditor`: missing non-core features or deep logic vs original.
  - `prod-readiness-auditor`: observability (logs, metrics, sentry), graceful shutdown, health checks.
  - `security-auditor`: rate limiting, validation, RBAC, secret management.
  - `perf-auditor`: N+1 queries, missing indexes, bundle size, caching.
- **Output:** `ralph/harden-gap.json` (typed backlog of improvements).

### Phase 5: RESHAPE (Architecture)
- **Input:** `ralph/harden-gap.json`, current `README.md`.
- **Action:** Architect + Critic agents decide structural changes.
- **Deliverable:** `ralph/reshape-plan.md` (no code, just decisions).
- **Consensus Gate:** Both agents must agree on the plan before implementation.

### Phase 6: HARDEN (Execution)
- **Input:** `ralph/reshape-plan.md`, `ralph/harden-gap.json`.
- **Action:** Parallel execution agents burn down gaps in priority order.
- **Rule:** One gap = One branch/commit = One verifier pass.
- **Verifier Gate:**
  - Security → sec-reviewer agent.
  - Perf → k6 load test or profiler run.
  - Feature → e2e/unit tests.
  - Infra → smoke deployment check.

### Phase 7: CANARY (Rollout)
- **Input:** Fully hardened source.
- **Action:** Graduated rollout to a staging/production-like environment.
- **Checks:** Health checks, synthetic load, SLO monitoring (error rate, latency).
- **Failure:** Auto-rollback and re-queue the offending gap.

### Phase 8: LEARN (Feedback)
- **Input:** Harden commit history.
- **Action:** Pattern-extractor agent creates/updates upstream templates.
- **Output:** New profiles in `.claude/skills/`, improved `prd-schema.json`, better build prompts.
- **Goal:** The next build loop run should not repeat the same mistakes.

## Key Artifacts

### ralph/harden-gap.json
The canonical backlog for Phases 6-7.
- `id`: unique gap ID.
- `kind`: feature | security | perf | infra | arch.
- `severity`: critical | high | medium | low.
- `evidence`: log tail, code snippet, or screenshot ref.
- `passes`: boolean (verified by verifier).

### ralph/reshape-plan.md
Human-readable (but machine-parseable) architectural roadmap.

## Integration

The `harden-watchdog.sh` orchestrator extends the `ralph-watchdog.sh` logic to manage Phase 4-8 transitions.

---

_Build fast. Harden honestly._
