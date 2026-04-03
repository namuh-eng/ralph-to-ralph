# Pre-Loop Onboarding — Implementation Ready

**Branch:** `feat/pre-loop-onboarding`
**Status:** Plan approved (Architect + Critic consensus)
**Date:** 2026-04-02

## Quick Summary

Adds `onboard.sh` — a pre-loop script that asks users what product to clone, researches the target's technical architecture, recommends a tech stack (AWS/GCP/Azure), checks dependencies, installs packages, and rewrites 9 hardcoded config files before the build loop starts.

## Files

| Artifact | Path |
|----------|------|
| Spec (from deep interview) | `.omc/specs/deep-interview-pre-loop-onboarding.md` |
| Implementation plan | `.omc/plans/onboarding-consensus-plan.md` |

## What Gets Built (8 steps)

1. Fix SSL checks in `db/index.ts` + `drizzle.config.ts` (replace `amazonaws.com` with `DB_SSL` env var)
2. Create `.env.example` with all project env vars
2b. Fix `inspect-ralph.sh` to read `@pre-setup.md @ralph-config.json`
2c. Fix `qa-ralph.sh` + `build-ralph.sh` to read `@ralph-config.json`
3. Create `onboard-prompt.md` (core prompt — rewrites 9 files)
4. Create `onboard.sh` (bash wrapper with schema validation)
5. Add `ralph-config.json` to `.gitignore`
6. Update `README.md`
7. Write tests
8. Manual E2E validation with Resend, Mintlify, and a dev-tools product

## Prompt to Launch

Copy-paste this when ready:

```
Implement the onboarding feature from the approved plan at .omc/plans/onboarding-consensus-plan.md
on branch feat/pre-loop-onboarding. The spec is at .omc/specs/deep-interview-pre-loop-onboarding.md.
Follow the plan's 8 steps in order. Run make check && make test after code changes.
```
