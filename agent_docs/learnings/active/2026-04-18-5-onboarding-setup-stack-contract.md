---
date: 2026-04-18
issue: "#5"
type: decision
promoted_to: null
---

## Onboarding must run setup-stack.sh after writing ralph-config.json

**What:** Both onboarding paths (bash wrapper and Claude Code skill) must write `ralph-config.json` first, then invoke `setup-stack.sh`. The script stamps `.ralph-setup-done`, which is what the Makefile guard checks before allowing `make check`/`make test` to run.

**Why:** `ralph-config.json` is excluded from Biome's formatter by design — Python's `json.dump` produces valid JSON that Biome would reformat, breaking `make check` immediately after onboarding. The ignore entry in `biome.json` is intentional, not an oversight. Skipping `setup-stack.sh` (or writing tsconfig/package.json inline instead of via the script) leaves the Makefile guard in a locked state.

**Fix:** Any new onboarding path or template must: (1) write `ralph-config.json`, (2) call `setup-stack.sh`, (3) never inline-write files the script owns. If `make check` fails right after onboarding, check `.ralph-setup-done` exists and `ralph-config.json` is in `biome.json`'s ignore list.
