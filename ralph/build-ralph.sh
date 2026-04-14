#!/bin/bash
# Phase 2: Build a clone from the generated PRD and build spec
# Each iteration = exactly 1 feature (enforced by prompt + NEXT/COMPLETE promises)
set -euo pipefail
cd "$(dirname "$0")/.."

# macOS does not ship GNU timeout — use gtimeout from coreutils or provide a fallback
if ! command -v timeout &>/dev/null; then
  if command -v gtimeout &>/dev/null; then
    timeout() { gtimeout "$@"; }
  else
    timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
  fi
fi

# Resolve Python: prefer `uv run python3` if uv is available, fall back to bare python3
if command -v uv &>/dev/null; then
  PY="uv run python3"
else
  PY="python3"
fi

ITERATIONS="${1:-999}"

[ -f ralph-config.json ] || { echo "ERROR: ralph-config.json not found. Run ./ralph/onboard.sh first."; exit 1; }

if [ ! -f "prd.json" ]; then
  echo "Error: prd.json not found. Run inspect-ralph.sh first."
  exit 1
fi

if [ ! -f "build-spec.md" ]; then
  echo "Error: build-spec.md not found. Run inspect-ralph.sh first."
  exit 1
fi

echo "=== RALPH-TO-RALPH: Phase 2 (Build) ==="
echo "Iterations: $ITERATIONS"
echo ""

# Initialize
touch build-progress.txt

count_passes() {
  $PY -c "import json; d=json.load(open('prd.json')); print(sum(1 for x in d if x.get('build_pass', False)))" 2>/dev/null || echo "0"
}
total_tasks() {
  $PY -c "import json; print(len(json.load(open('prd.json'))))" 2>/dev/null || echo "0"
}

# Get QA failure context for the next feature to build (if any)
get_qa_context() {
  $PY -c "
import json, sys

# Find the first feature where build_pass is false
prd = json.load(open('prd.json'))
target = None
for item in prd:
    if not item.get('build_pass', False):
        target = item
        break

if not target:
    print('')
    sys.exit(0)

feature_id = target['id']

# Check if qa-report.json exists and has entries for this feature
try:
    report = json.load(open('qa-report.json'))
    failures = [r for r in report if r.get('feature_id') == feature_id]
    if not failures:
        print('')
        sys.exit(0)
except:
    print('')
    sys.exit(0)

# Build QA context summary
lines = []
lines.append(f'=== QA FAILURE CONTEXT FOR {feature_id} ===')
lines.append(f'This feature was PREVIOUSLY BUILT but FAILED QA {len(failures)} time(s).')
lines.append(f'You must analyze the root cause — do NOT just patch symptoms.')
lines.append('')

for attempt in failures:
    lines.append(f'--- QA Attempt {attempt.get(\"attempt\", \"?\")} ---')
    lines.append(f'Status: {attempt.get(\"status\", \"unknown\")}')
    bugs = attempt.get('bugs_found', [])
    if bugs:
        lines.append('Bugs found:')
        for bug in bugs:
            if isinstance(bug, dict):
                lines.append(f'  - [{bug.get(\"severity\", \"?\")}] {bug.get(\"description\", str(bug))}')
                if bug.get('file'):
                    lines.append(f'    File: {bug[\"file\"]}')
                if bug.get('steps_to_reproduce'):
                    lines.append(f'    Steps: {bug[\"steps_to_reproduce\"]}')
            else:
                lines.append(f'  - {bug}')
    tested = attempt.get('tested_steps', [])
    if tested:
        lines.append('What was tested:')
        for step in tested:
            lines.append(f'  - {step}')
    lines.append('')

# Find dependent features that might be affected
deps = target.get('dependent_on', [])
if deps:
    lines.append('DEPENDENT FEATURES (check these for shared root causes):')
    for dep_id in deps:
        dep_item = next((x for x in prd if x['id'] == dep_id), None)
        if dep_item:
            qa_status = 'qa_pass' if dep_item.get('qa_pass') else 'qa_fail/untested'
            lines.append(f'  - {dep_id}: {dep_item.get(\"description\", \"\")[:80]} [{qa_status}]')
    lines.append('')

# Find features that depend ON this one (downstream impact)
downstream = [x for x in prd if feature_id in (x.get('dependent_on') or [])]
if downstream:
    lines.append('DOWNSTREAM FEATURES (depend on this — your fix may affect them):')
    for ds in downstream:
        lines.append(f'  - {ds[\"id\"]}: {ds.get(\"description\", \"\")[:80]}')
    lines.append('')

print('\n'.join(lines))
" 2>/dev/null || echo ""
}

for ((i=1; i<=$ITERATIONS; i++)); do
  PASSES=$(count_passes)
  TOTAL=$(total_tasks)
  echo "--- Build iteration $i/$ITERATIONS ($PASSES/$TOTAL passed) ---"

  # Check if all done before invoking
  if [ "$PASSES" -ge "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo "All $TOTAL features already build_pass!"
    exit 0
  fi

  # Check for QA failure context
  QA_CONTEXT=$(get_qa_context)

  if [ -n "$QA_CONTEXT" ]; then
    # REBUILD MODE: Feature failed QA previously — use root-cause analysis prompt
    echo "  → Rebuild mode: QA failures detected, providing root-cause context"

    result=$(timeout 1200 claude -p --dangerously-skip-permissions --model claude-opus-4-6 \
"@ralph/build-prompt.md @ralph/pre-setup.md @build-spec.md @prd.json @build-progress.txt @CLAUDE.md @ralph-config.json @qa-report.json

ITERATION: $i of $ITERATIONS
PROGRESS: $PASSES/$TOTAL features build_pass
MODE: REBUILD — This feature previously failed QA. Read the failure context below carefully.

$QA_CONTEXT

REBUILD INSTRUCTIONS:
You are rebuilding a feature that FAILED QA. Do NOT just patch the reported symptom.
Follow this process:

1. **Read the QA failure context above** — understand exactly what broke and how.
2. **Trace the root cause** — read ALL related source files, not just the file where the bug appeared. The real bug is often in a shared utility, a data model, or a dependency.
3. **Check dependent features** — if this feature depends on others (listed above), read their code too. A bug in a dependency can cascade.
4. **Check downstream features** — if other features depend on this one (listed above), make sure your fix doesn't break them.
5. **Consider refactoring** if the bug stems from a structural issue (wrong data model, shared utility with bad assumptions, tight coupling). A targeted refactor that fixes the root cause is better than a narrow patch that will fail QA again.
6. **Fix the root cause**, not just the symptom. If 3 features share a broken utility, fix the utility once.
7. **Write or update tests** that specifically cover the failure scenario from the QA report.
8. **Run make check && make test** — ALL tests must pass, including tests for dependent features.
9. Set build_pass: true, commit, push.

Output <promise>NEXT</promise> when done with this feature.
Output <promise>COMPLETE</promise> only if ALL features pass.")

  else
    # FRESH BUILD MODE: No QA failures — standard build prompt
    result=$(timeout 1200 claude -p --dangerously-skip-permissions --model claude-opus-4-6 \
"@ralph/build-prompt.md @ralph/pre-setup.md @build-spec.md @prd.json @build-progress.txt @CLAUDE.md @ralph-config.json

ITERATION: $i of $ITERATIONS
PROGRESS: $PASSES/$TOTAL features build_pass

Build exactly ONE feature (the first build_pass:false entry), then commit, push, and stop.
Output <promise>NEXT</promise> when done with this feature.
Output <promise>COMPLETE</promise> only if ALL features pass.")
  fi

  echo "$result"

  if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
    echo ""
    echo "=== Build complete after $i iterations! All $(total_tasks) features pass. ==="
    exit 0
  fi

  if [[ "$result" == *"<promise>NEXT</promise>"* ]]; then
    echo "Feature done. Moving to next iteration..."
    continue
  fi

  # If neither promise found, agent may have hit context limit or errored
  echo "WARNING: No promise found. Agent may have crashed or hit context limit. Restarting..."
  sleep 3
done

echo ""
echo "=== Build finished after $ITERATIONS iterations ==="
echo "Passes: $(count_passes)/$(total_tasks). Check prd.json for remaining."
