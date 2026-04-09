#!/bin/bash
# Phase 3: QA evaluation using Codex as independent evaluator
# Passes the current feature + its dependencies to Codex to give context without overflow
# Sub-phases: FUNCTIONAL → API CONTRACT → SECURITY → ACCESSIBILITY
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_URL="${1:-}"
ITERATIONS="${2:-999}"
MAX_RETRIES=5

[ -f ralph-config.json ] || { echo "ERROR: ralph-config.json not found. Run ./ralph/onboard.sh first."; exit 1; }
BROWSER_AGENT=$(python3 -c "import json; print(json.load(open('ralph-config.json')).get('browserAgent', 'ever'))" 2>/dev/null || echo "ever")

if [ ! -f "prd.json" ]; then
  echo "Error: prd.json not found. Run build-ralph.sh first."
  exit 1
fi

echo "=== RALPH-TO-RALPH: Phase 3 (QA with Codex) ==="
echo "Target: ${TARGET_URL:-none}"
echo "Sub-phases: FUNCTIONAL → API CONTRACT → SECURITY → ACCESSIBILITY"
echo ""

# Initialize
if [ ! -f "qa-report.json" ]; then
  echo '[]' > qa-report.json
fi

# Initialize qa-report-summary.json with schema
if [ ! -f "qa-report-summary.json" ]; then
  python3 -c "
import json
summary = {
  'schema_version': '2.0',
  'sub_phases': ['functional', 'api_contract', 'security', 'accessibility'],
  'totals': {
    'features_total': 0,
    'features_passed': 0,
    'features_failed': 0,
    'features_exhausted': 0
  },
  'sub_phase_totals': {
    'functional':    {'pass': 0, 'fail': 0, 'skip': 0},
    'api_contract':  {'pass': 0, 'fail': 0, 'skip': 0},
    'security':      {'pass': 0, 'fail': 0, 'skip': 0},
    'accessibility': {'pass': 0, 'fail': 0, 'skip': 0}
  },
  'features': []
}
json.dump(summary, open('qa-report-summary.json', 'w'), indent=2)
print('Initialized qa-report-summary.json')
"
fi

# Start dev server in background
npm run dev &
DEV_PID=$!
echo "Dev server started (PID: $DEV_PID)"
if [ "$BROWSER_AGENT" = "ever" ]; then
  trap 'kill $DEV_PID 2>/dev/null; ever stop 2>/dev/null' EXIT
else
  trap 'kill $DEV_PID 2>/dev/null' EXIT
fi
sleep 5

# Run Playwright regression suite first
if [ -f "playwright.config.ts" ] || [ -d "tests/e2e" ]; then
  echo "--- Running Playwright regression suite ---"
  npx playwright test --reporter=list 2>&1 || echo "Some Playwright tests failed — QA agent will investigate."
  echo ""
fi

# Start browser agent session for QA
if [ "$BROWSER_AGENT" = "ever" ]; then
  ever start --url http://localhost:3015
  echo "Ever CLI session started for QA."
fi
echo ""

# Build target URL context
TARGET_CONTEXT=""
if [ -n "$TARGET_URL" ]; then
  TARGET_CONTEXT="
TARGET_URL: $TARGET_URL
When confused about how a feature should work, use 'ever start --url $TARGET_URL' to check the original product."
fi

# ── Helper: get next feature where qa_pass is not true ──
get_next_feature_with_deps() {
  python3 -c "
import json, sys
from collections import Counter

prd = json.load(open('prd.json'))
try:
    report = json.load(open('qa-report.json'))
except: report = []

# Features with qa_pass: true in prd.json are done
qa_passed = {item['id'] for item in prd if item.get('qa_pass', False)}

# Features that exhausted retries without qa_pass
attempt_counts = Counter(r['feature_id'] for r in report)
exhausted = {fid for fid, count in attempt_counts.items() if count >= $MAX_RETRIES and fid not in qa_passed}

done = qa_passed | exhausted
by_id = {item['id']: item for item in prd}

target = None
for item in prd:
    if item['id'] not in done:
        target = item
        break

if not target:
    print('ALL_DONE')
    sys.exit(0)

result = {'main': target, 'dependencies': []}
dep_ids = target.get('dependent_on', [])
for dep_id in dep_ids:
    if dep_id in by_id:
        result['dependencies'].append(by_id[dep_id])

print(json.dumps(result))
" 2>/dev/null
}

# ── Helper: get current attempt number for a feature ──
get_attempt_number() {
  local feature_id="$1"
  python3 -c "
import json
try:
    report = json.load(open('qa-report.json'))
    attempts = [r for r in report if r['feature_id'] == '$feature_id']
    print(len(attempts) + 1)
except: print(1)
" 2>/dev/null
}

# ── Helper: get full attempt history for a feature ──
get_feature_history() {
  local feature_id="$1"
  python3 -c "
import json
try:
    report = json.load(open('qa-report.json'))
    attempts = [r for r in report if r['feature_id'] == '$feature_id']
    if not attempts:
        print('No previous attempts.')
    else:
        for a in attempts:
            num = a.get('attempt', '?')
            status = a.get('status', '?')
            bugs = a.get('bugs_found', [])
            fix_desc = a.get('fix_description', 'no description')
            sub = a.get('sub_phases', {})
            print(f'Attempt {num}: status={status}, fix tried: {fix_desc}')
            for phase, pdata in sub.items():
                if isinstance(pdata, dict):
                    print(f'  [{phase}] {pdata.get(\"status\",\"?\")} — {pdata.get(\"notes\",\"\")}')
            for b in bugs:
                if isinstance(b, dict):
                    phase_tag = f'[{b.get(\"phase\",\"?\")}] ' if 'phase' in b else ''
                    print(f'  - {phase_tag}[{b.get(\"severity\",\"?\")}] {b.get(\"description\",\"\")}')
                else:
                    print(f'  - {b}')
except Exception as e:
    print(f'Error reading history: {e}')
" 2>/dev/null
}

total_features() {
  python3 -c "import json; print(len(json.load(open('prd.json'))))" 2>/dev/null || echo "0"
}

# Count features that are done (qa_pass: true or exhausted retries)
tested_count() {
  python3 -c "
import json
from collections import Counter
try:
    prd = json.load(open('prd.json'))
    report = json.load(open('qa-report.json'))
    qa_passed = {item['id'] for item in prd if item.get('qa_pass', False)}
    attempt_counts = Counter(r['feature_id'] for r in report)
    exhausted = {fid for fid, count in attempt_counts.items() if count >= $MAX_RETRIES and fid not in qa_passed}
    print(len(qa_passed | exhausted))
except: print(0)
" 2>/dev/null || echo "0"
}

# ── Helper: update qa-report-summary.json after each feature ──
update_summary() {
  python3 -c "
import json
from collections import Counter

try:
    prd = json.load(open('prd.json'))
    report = json.load(open('qa-report.json'))
    summary = json.load(open('qa-report-summary.json'))
except Exception as e:
    print(f'Summary update error: {e}')
    exit(0)

MAX_RETRIES = $MAX_RETRIES
qa_passed = {item['id'] for item in prd if item.get('qa_pass', False)}
attempt_counts = Counter(r['feature_id'] for r in report)
exhausted = {fid for fid, count in attempt_counts.items() if count >= MAX_RETRIES and fid not in qa_passed}

summary['totals']['features_total'] = len(prd)
summary['totals']['features_passed'] = len(qa_passed)
summary['totals']['features_failed'] = len([f for f in prd if f['id'] not in qa_passed and f['id'] not in exhausted and attempt_counts.get(f['id'], 0) > 0])
summary['totals']['features_exhausted'] = len(exhausted)

# Reset sub-phase totals
for phase in ['functional', 'api_contract', 'security', 'accessibility']:
    summary['sub_phase_totals'][phase] = {'pass': 0, 'fail': 0, 'skip': 0}

# Aggregate sub-phase results from the latest attempt per feature
latest_attempts = {}
for entry in report:
    fid = entry['feature_id']
    if fid not in latest_attempts or entry.get('attempt', 0) > latest_attempts[fid].get('attempt', 0):
        latest_attempts[fid] = entry

for entry in latest_attempts.values():
    sub = entry.get('sub_phases', {})
    for phase in ['functional', 'api_contract', 'security', 'accessibility']:
        st = sub.get(phase, {}).get('status', 'skip')
        if st in ('pass', 'fail', 'skip'):
            summary['sub_phase_totals'][phase][st] += 1

# Build per-feature summary list
feature_list = []
for item in prd:
    fid = item['id']
    entry = latest_attempts.get(fid)
    feature_entry = {
        'feature_id': fid,
        'description': item.get('description', '')[:80],
        'category': item.get('category', ''),
        'qa_pass': item.get('qa_pass', False),
        'attempts': attempt_counts.get(fid, 0),
        'exhausted': fid in exhausted,
        'sub_phases': {}
    }
    if entry:
        feature_entry['overall_status'] = entry.get('status', 'unknown')
        feature_entry['sub_phases'] = {
            phase: entry.get('sub_phases', {}).get(phase, {'status': 'skip', 'notes': ''})
            for phase in ['functional', 'api_contract', 'security', 'accessibility']
        }
    feature_list.append(feature_entry)

summary['features'] = feature_list
json.dump(summary, open('qa-report-summary.json', 'w'), indent=2)
print('Updated qa-report-summary.json')
" 2>/dev/null
}

# ── MAIN LOOP ──
for ((i=1; i<=$ITERATIONS; i++)); do
  TESTED=$(tested_count)
  TOTAL=$(total_features)
  echo "--- QA iteration $i ($TESTED/$TOTAL done) ---"
  echo "    Sub-phases: FUNCTIONAL | API CONTRACT | SECURITY | ACCESSIBILITY"

  FEATURE_BUNDLE=$(get_next_feature_with_deps)

  if [ "$FEATURE_BUNDLE" = "ALL_DONE" ]; then
    echo "All features have been QA tested!"
    break
  fi

  FEATURE_ID=$(echo "$FEATURE_BUNDLE" | python3 -c "import json,sys; print(json.load(sys.stdin)['main']['id'])")
  FEATURE_CAT=$(echo "$FEATURE_BUNDLE" | python3 -c "import json,sys; print(json.load(sys.stdin)['main'].get('category',''))")
  DEP_COUNT=$(echo "$FEATURE_BUNDLE" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['dependencies']))")
  ATTEMPT=$(get_attempt_number "$FEATURE_ID")
  HISTORY=$(get_feature_history "$FEATURE_ID")

  echo "Testing: $FEATURE_ID ($FEATURE_CAT) — attempt $ATTEMPT/$MAX_RETRIES, $DEP_COUNT dependencies"

  echo "$FEATURE_BUNDLE" > .current-feature.json

  QA_HINTS=$(python3 -c "
import json
try:
    hints = json.load(open('qa-hints.json'))
    for h in hints:
        if h.get('feature_id') == '$FEATURE_ID':
            print('Tests written by build agent: ' + ', '.join(h.get('tests_written', [])))
            print('NEEDS DEEPER QA:')
            for q in h.get('needs_deeper_qa', []):
                print('  - ' + q)
            break
    else:
        print('No QA hints from build agent for this feature.')
except:
    print('No qa-hints.json found.')
" 2>/dev/null)

  result=$(timeout 1200 codex exec --dangerously-bypass-approvals-and-sandbox \
"$(cat ralph/qa-prompt.md)

== FEATURE TO TEST ==
$(python3 -c "import json; d=json.load(open('.current-feature.json')); print(json.dumps(d['main'], indent=2))")

== RELATED FEATURES (dependencies for context) ==
$(python3 -c "
import json
d=json.load(open('.current-feature.json'))
deps = d.get('dependencies', [])
if deps:
    for dep in deps:
        print(f'- {dep[\"id\"]}: {dep[\"description\"][:100]}')
else:
    print('No dependencies listed.')
")

== BUILD AGENT QA HINTS ==
$QA_HINTS

== QA HISTORY FOR THIS FEATURE (ALL PREVIOUS ATTEMPTS) ==
$HISTORY

Read these files as needed:
@ralph/pre-setup.md
@qa-report.json
@ralph/ever-cli-reference.md
@ralph-config.json

QA PROGRESS: $TESTED/$TOTAL features done
FEATURE: $FEATURE_ID (category: $FEATURE_CAT)
ATTEMPT: $ATTEMPT of $MAX_RETRIES
${TARGET_CONTEXT}

Test this ONE feature thoroughly across ALL FOUR sub-phases:
  A. FUNCTIONAL  — UI flows, unit tests, E2E tests
  B. API CONTRACT — curl each endpoint, verify status codes + response shapes + error formats
  C. SECURITY    — auth bypass, input sanitization, CORS, sensitive data exposure
  D. ACCESSIBILITY — axe-core scan + manual keyboard/label checks

Study the QA history above — if previous attempts failed, try a different approach.
Then:
1. Append a NEW entry to qa-report.json with attempt: $ATTEMPT and sub_phases results (do not overwrite previous entries)
2. Fix any critical/major bugs you find
3. Set qa_pass: true in prd.json if all critical bugs are fixed, qa_pass: false if bugs remain
4. Run make check && make test
5. git add -A && git commit && git push
6. Output <promise>NEXT</promise> when done.")

  echo "$result"
  rm -f .current-feature.json

  # Update the aggregated summary after each feature attempt
  update_summary

  if [[ "$result" == *"<promise>NEXT</promise>"* ]]; then
    echo "QA attempt $ATTEMPT for $FEATURE_ID done (all sub-phases). Moving to next..."
    continue
  fi

  # No promise = crash or context overflow. Record as partial and move on.
  echo "WARNING: No promise from Codex for $FEATURE_ID (attempt $ATTEMPT). Recording as partial..."
  python3 -c "
import json
report = json.load(open('qa-report.json'))
report.append({
    'feature_id': '$FEATURE_ID',
    'attempt': $ATTEMPT,
    'status': 'partial',
    'sub_phases': {
        'functional':    {'status': 'skip', 'notes': 'Codex crashed or timed out'},
        'api_contract':  {'status': 'skip', 'notes': 'Codex crashed or timed out'},
        'security':      {'status': 'skip', 'notes': 'Codex crashed or timed out'},
        'accessibility': {'status': 'skip', 'notes': 'Codex crashed or timed out'}
    },
    'tested_steps': ['Codex crashed or timed out'],
    'bugs_found': [],
    'fix_description': 'Codex did not complete'
})
json.dump(report, open('qa-report.json', 'w'), indent=2)
"
  update_summary
  sleep 3
done

# Run full E2E regression at the end
echo ""
echo "--- Running final Playwright regression suite ---"
npx playwright test --reporter=list 2>&1 || echo "Some Playwright tests failed in final regression."
echo ""

# Final summary update
update_summary

TESTED=$(tested_count)
TOTAL=$(total_features)
echo ""
echo "=== QA finished: $TESTED/$TOTAL features done ==="
echo "Check qa-report.json for per-feature details."
echo "Check qa-report-summary.json for aggregated sub-phase results."
