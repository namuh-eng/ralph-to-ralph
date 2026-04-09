#!/bin/bash
# ralph-watchdog.sh - Runs loops in foreground with restart logic
#
# Flow:
#   1. Run inspect loop → restart if it stops before completing
#   2. Run build loop → restart if it stops before all passed
#   3. Run QA loop → if bugs found, restart build then QA
#
# Usage: ./ralph/ralph-watchdog.sh <target-url>

set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_URL="${1:?Usage: $0 <target-url>}"
LOCKFILE=".ralph-watchdog.lock"
LOG_FILE="ralph-watchdog-$(date +%Y%m%d-%H%M%S).log"
COST_LOG="ralph/cost-log.json"
FAILURE_LOG="ralph/failure-log.json"

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# Resolve Python: prefer `uv run python3` if uv is available, fall back to bare python3
if command -v uv &>/dev/null; then
  PY="uv run python3"
else
  PY="python3"
fi

# Lock file
if [ -f "$LOCKFILE" ]; then
  PID=$(cat "$LOCKFILE" 2>/dev/null)
  if kill -0 "$PID" 2>/dev/null; then
    echo "Watchdog already running (PID $PID)."
    exit 0
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
_BROWSER_AGENT=$($PY -c "import json; print(json.load(open('ralph-config.json')).get('browserAgent', 'ever'))" 2>/dev/null || echo "ever")
if [ "$_BROWSER_AGENT" = "ever" ]; then
  trap 'rm -f "$LOCKFILE"; ever stop 2>/dev/null' EXIT
else
  trap 'rm -f "$LOCKFILE"' EXIT
fi

# ─── Cost Tracking ───

COST_BUDGET=$($PY -c "
import json, sys
try:
    cfg = json.load(open('ralph-config.json'))
    print(cfg.get('maxBudget', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

init_cost_log() {
  if [ ! -f "$COST_LOG" ]; then
    $PY -c "
import json
data = {
  'total_cost_usd': 0.0,
  'total_input_tokens': 0,
  'total_output_tokens': 0,
  'budget_usd': $COST_BUDGET,
  'entries': []
}
with open('$COST_LOG', 'w') as f:
    json.dump(data, f, indent=2)
"
  fi
}

update_cost() {
  local phase="$1"
  local feature="${2:-unknown}"
  local log_snippet="$3"

  $PY -c "
import json, re, sys
from datetime import datetime

phase = '$phase'
feature = '$feature'
log_text = '''$log_snippet'''

# Parse token usage from Claude output patterns
input_tokens = 0
output_tokens = 0

patterns = [
    r'input[_ ]tokens?[:\s]+([0-9,]+)',
    r'\"input_tokens\":\s*([0-9]+)',
    r'Input:\s*([0-9,]+)\s*tokens',
]
for pat in patterns:
    m = re.search(pat, log_text, re.IGNORECASE)
    if m:
        input_tokens = int(m.group(1).replace(',', ''))
        break

patterns = [
    r'output[_ ]tokens?[:\s]+([0-9,]+)',
    r'\"output_tokens\":\s*([0-9]+)',
    r'Output:\s*([0-9,]+)\s*tokens',
]
for pat in patterns:
    m = re.search(pat, log_text, re.IGNORECASE)
    if m:
        output_tokens = int(m.group(1).replace(',', ''))
        break

# Claude claude-opus-4-6 pricing: \$15/1M input, \$75/1M output
cost_usd = (input_tokens / 1_000_000) * 15.0 + (output_tokens / 1_000_000) * 75.0

try:
    with open('$COST_LOG') as f:
        data = json.load(f)
except:
    data = {'total_cost_usd': 0.0, 'total_input_tokens': 0, 'total_output_tokens': 0, 'budget_usd': $COST_BUDGET, 'entries': []}

data['total_cost_usd'] += cost_usd
data['total_input_tokens'] += input_tokens
data['total_output_tokens'] += output_tokens
data['entries'].append({
    'timestamp': datetime.utcnow().isoformat(),
    'phase': phase,
    'feature': feature,
    'input_tokens': input_tokens,
    'output_tokens': output_tokens,
    'cost_usd': round(cost_usd, 6)
})

with open('$COST_LOG', 'w') as f:
    json.dump(data, f, indent=2)

# Print cost summary
total = data['total_cost_usd']
budget = data['budget_usd']
print(f'COST_UPDATE total={total:.4f} budget={budget}')
" 2>/dev/null || true
}

check_budget() {
  if [ "$COST_BUDGET" = "0" ] || [ -z "$COST_BUDGET" ]; then
    return 0
  fi

  $PY -c "
import json, sys

try:
    data = json.load(open('$COST_LOG'))
except:
    sys.exit(0)

total = data.get('total_cost_usd', 0.0)
budget = data.get('budget_usd', 0.0)
if budget <= 0:
    sys.exit(0)

pct = (total / budget) * 100

if pct >= 100:
    print(f'BUDGET_EXCEEDED total=\${total:.4f} budget=\${budget:.2f}')
    sys.exit(2)
elif pct >= 90:
    print(f'BUDGET_ALERT_90 {pct:.1f}% used (\${total:.4f}/\${budget:.2f})')
elif pct >= 75:
    print(f'BUDGET_ALERT_75 {pct:.1f}% used (\${total:.4f}/\${budget:.2f})')
elif pct >= 50:
    print(f'BUDGET_ALERT_50 {pct:.1f}% used (\${total:.4f}/\${budget:.2f})')
" 2>/dev/null
  local budget_status=$?
  if [ "$budget_status" -eq 2 ]; then
    log "BUDGET EXCEEDED — stopping. See $COST_LOG for details."
    print_cost_summary
    exit 1
  fi
}

print_cost_summary() {
  $PY -c "
import json
try:
    data = json.load(open('$COST_LOG'))
    total = data.get('total_cost_usd', 0.0)
    budget = data.get('budget_usd', 0.0)
    inp = data.get('total_input_tokens', 0)
    out = data.get('total_output_tokens', 0)
    print(f'  Total cost: \${total:.4f}')
    if budget > 0:
        pct = (total / budget) * 100
        print(f'  Budget: \${budget:.2f} ({pct:.1f}% used)')
    print(f'  Tokens: {inp:,} input / {out:,} output')
    entries = data.get('entries', [])
    if entries:
        by_phase = {}
        for e in entries:
            ph = e.get('phase', 'unknown')
            by_phase[ph] = by_phase.get(ph, 0.0) + e.get('cost_usd', 0.0)
        print('  Cost by phase:')
        for ph, cost in sorted(by_phase.items(), key=lambda x: -x[1]):
            print(f'    {ph}: \${cost:.4f}')
except Exception as ex:
    print(f'  (cost log unavailable: {ex})')
" 2>/dev/null || true
}

# ─── Failure Analysis & Smart Retry ───

init_failure_log() {
  if [ ! -f "$FAILURE_LOG" ]; then
    echo '{"failures": []}' > "$FAILURE_LOG"
  fi
}

analyze_failure() {
  local phase="$1"
  local feature="${2:-unknown}"
  local exit_code="${3:-1}"
  local log_tail="$4"

  $PY -c "
import json, re
from datetime import datetime

phase = '$phase'
feature = '$feature'
exit_code = int('$exit_code')
log_text = '''$log_tail'''

# Categorize failure
category = 'unknown'

if exit_code == 124 or 'timeout' in log_text.lower() or 'timed out' in log_text.lower():
    category = 'timeout'
elif re.search(r'context.{0,20}(overflow|limit|too long|window)', log_text, re.IGNORECASE):
    category = 'context_overflow'
elif re.search(r'(rate.?limit|429|too many requests|quota)', log_text, re.IGNORECASE):
    category = 'api_error'
elif re.search(r'(compilation.?fail|type.?error|build.?fail|tsc|typescript)', log_text, re.IGNORECASE):
    category = 'compilation_failure'
elif re.search(r'(test.?fail|assertion|expect.*received|FAIL|playwright)', log_text, re.IGNORECASE):
    category = 'test_failure'
elif re.search(r'(api.?error|network|connection|ECONNREFUSED)', log_text, re.IGNORECASE):
    category = 'api_error'

# Load failure log
try:
    with open('$FAILURE_LOG') as f:
        data = json.load(f)
except:
    data = {'failures': []}

# Count prior failures for this feature in this phase
prior = sum(1 for e in data['failures']
            if e.get('feature') == feature and e.get('phase') == phase)

entry = {
    'timestamp': datetime.utcnow().isoformat(),
    'phase': phase,
    'feature': feature,
    'exit_code': exit_code,
    'category': category,
    'attempt': prior + 1
}
data['failures'].append(entry)

with open('$FAILURE_LOG', 'w') as f:
    json.dump(data, f, indent=2)

print(f'FAILURE_CATEGORY={category} ATTEMPT={prior + 1}')
" 2>/dev/null || echo "FAILURE_CATEGORY=unknown ATTEMPT=1"
}

get_failure_count() {
  local phase="$1"
  local feature="${2:-unknown}"

  $PY -c "
import json
try:
    data = json.load(open('$FAILURE_LOG'))
    count = sum(1 for e in data['failures']
                if e.get('feature') == feature and e.get('phase') == phase)
    print(count)
except:
    print(0)
" 2>/dev/null || echo "0"
}

get_retry_flags() {
  local category="$1"
  local flags=""

  case "$category" in
    context_overflow)
      flags="--max-tokens 4096"
      ;;
    timeout)
      flags="--timeout-extend"
      ;;
    *)
      flags=""
      ;;
  esac
  echo "$flags"
}

# ─── Adaptive Timeouts ───

# RALPH_TIMEOUT_MULTIPLIER can be set externally to scale all timeouts
TIMEOUT_MULTIPLIER="${RALPH_TIMEOUT_MULTIPLIER:-1}"

get_feature_timeout() {
  local feature_id="${1:-}"
  local base_timeout=900  # default

  if [ -n "$feature_id" ]; then
    base_timeout=$($PY -c "
import json, sys

feature_id = '$feature_id'
try:
    prd = json.load(open('prd.json'))
    feature = next((x for x in prd if str(x.get('id', '')) == feature_id), None)
    if not feature:
        print(900)
        sys.exit(0)
    priority = str(feature.get('priority', 'P3')).upper().strip()
    # P0 = highest, P6 = lowest
    if priority == 'P0':
        print(1800)
    elif priority in ('P1', 'P2', 'P3'):
        print(1200)
    else:
        print(600)
except Exception as ex:
    print(900)
" 2>/dev/null || echo "900")
  fi

  # Add 300s if this feature has prior QA failures
  local qa_failures=0
  if [ -n "$feature_id" ]; then
    qa_failures=$(get_failure_count "qa" "$feature_id")
  fi
  if [ "$qa_failures" -gt 0 ]; then
    base_timeout=$((base_timeout + 300))
  fi

  # Apply global multiplier (float multiply via python)
  local final_timeout
  final_timeout=$($PY -c "print(int($base_timeout * $TIMEOUT_MULTIPLIER))" 2>/dev/null || echo "$base_timeout")
  echo "$final_timeout"
}

# ─── Helpers ───

count_passes() {
  $PY -c "
import json; d=json.load(open('prd.json'))
print(sum(1 for x in d if x.get('build_pass', False)))
" 2>/dev/null || echo "0"
}

total_tasks() {
  $PY -c "import json; print(len(json.load(open('prd.json'))))" 2>/dev/null || echo "0"
}

all_passed() {
  local total=$(total_tasks)
  local passed=$(count_passes)
  [ "$total" -gt 0 ] && [ "$passed" -ge "$total" ]
}

qa_complete() {
  $PY -c "
import json
prd = json.load(open('prd.json'))
unverified = [item['id'] for item in prd if not item.get('qa_pass', False)]
if unverified:
    print('false')
else:
    print('true')
" 2>/dev/null || echo "false"
}

inspect_done() {
  [ -f ".inspect-complete" ]
}

cron_backup() {
  git add -A 2>/dev/null
  git commit -m "watchdog backup $(date '+%H:%M') — $(count_passes)/$(total_tasks) passes" 2>/dev/null || true
  git push 2>/dev/null || true
}

run_phase_with_timeout() {
  local phase_cmd="$1"
  local timeout_sec="$2"
  local phase_log_file="$3"

  timeout "$timeout_sec" bash -c "$phase_cmd" > "$phase_log_file" 2>&1 || true
}

# ─── Init ───

START_TIME=$(date +%s)
log "=== Ralph-to-Ralph Watchdog Started ==="
log "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Target: $TARGET_URL"
if [ "$COST_BUDGET" != "0" ] && [ -n "$COST_BUDGET" ]; then
  log "Budget: \$$COST_BUDGET"
fi
if [ "$TIMEOUT_MULTIPLIER" != "1" ]; then
  log "Timeout multiplier: ${TIMEOUT_MULTIPLIER}x"
fi

init_cost_log
init_failure_log

# ─── PHASE 1: Inspect ───

MAX_INSPECT_RESTARTS=5
inspect_restarts=0
SKIP_INSPECT_FEATURES=()

while ! inspect_done; do
  if [ "$inspect_restarts" -ge "$MAX_INSPECT_RESTARTS" ]; then
    log "Phase 1: Hit max restarts ($MAX_INSPECT_RESTARTS). Aborting."
    exit 1
  fi

  log "Phase 1: Running inspect loop... (attempt $((inspect_restarts + 1)))"

  PHASE_LOG_TMP=$(mktemp)
  INSPECT_TIMEOUT=$(get_feature_timeout "")
  timeout "$INSPECT_TIMEOUT" ./ralph/inspect-ralph.sh "$TARGET_URL" 2>&1 | tee -a "$LOG_FILE" > "$PHASE_LOG_TMP" || true
  INSPECT_EXIT=${PIPESTATUS[0]}
  LOG_TAIL=$(tail -50 "$PHASE_LOG_TMP" | tr "'" ' ')

  # Cost tracking
  COST_INFO=$(update_cost "inspect" "inspect" "$LOG_TAIL")
  if echo "$COST_INFO" | grep -q "COST_UPDATE"; then
    BUDGET_MSG=$(check_budget 2>&1 || true)
    if echo "$BUDGET_MSG" | grep -q "BUDGET_ALERT"; then
      log "BUDGET WARNING: $BUDGET_MSG"
    fi
  fi
  rm -f "$PHASE_LOG_TMP"

  cron_backup

  if inspect_done; then
    log "Phase 1: Complete! $(total_tasks) features found."
    break
  else
    # Analyze failure
    FAILURE_INFO=$(analyze_failure "inspect" "inspect" "$INSPECT_EXIT" "$LOG_TAIL")
    FAILURE_CAT=$(echo "$FAILURE_INFO" | grep -o 'FAILURE_CATEGORY=[^ ]*' | cut -d= -f2)
    log "Phase 1: Inspect stopped (exit=$INSPECT_EXIT, category=$FAILURE_CAT). Restarting..."

    inspect_restarts=$((inspect_restarts + 1))
    sleep 5
  fi
done

# ─── PHASE 2 + 3: Build → QA → Fix loop ───

MAX_CYCLES=5
for ((cycle=1; cycle<=MAX_CYCLES; cycle++)); do
  log ""
  log "===== CYCLE $cycle/$MAX_CYCLES ====="

  check_budget

  # ─── PHASE 2: Build ───
  MAX_BUILD_RESTARTS=10
  build_restarts=0
  SKIPPED_FEATURES=()

  while ! all_passed; do
    if [ "$build_restarts" -ge "$MAX_BUILD_RESTARTS" ]; then
      log "Phase 2: Hit max restarts ($MAX_BUILD_RESTARTS). Moving to QA."
      break
    fi

    log "Phase 2: Building... $(count_passes)/$(total_tasks) passes (attempt $((build_restarts + 1)))"

    PHASE_LOG_TMP=$(mktemp)
    BUILD_TIMEOUT=$(get_feature_timeout "")
    timeout "$BUILD_TIMEOUT" ./ralph/build-ralph.sh 2>&1 | tee -a "$LOG_FILE" > "$PHASE_LOG_TMP" || true
    BUILD_EXIT=${PIPESTATUS[0]}
    LOG_TAIL=$(tail -80 "$PHASE_LOG_TMP" | tr "'" ' ')

    # Cost tracking
    COST_INFO=$(update_cost "build" "build_cycle_${cycle}" "$LOG_TAIL")
    BUDGET_CHECK=$(check_budget 2>&1 || true)
    if echo "$BUDGET_CHECK" | grep -q "BUDGET_ALERT"; then
      log "BUDGET WARNING: $BUDGET_CHECK"
    fi
    rm -f "$PHASE_LOG_TMP"

    cron_backup

    if all_passed; then
      log "Phase 2: All $(total_tasks) features pass!"
      break
    fi

    # Analyze failure
    FAILURE_INFO=$(analyze_failure "build" "build_cycle_${cycle}" "$BUILD_EXIT" "$LOG_TAIL")
    FAILURE_CAT=$(echo "$FAILURE_INFO" | grep -o 'FAILURE_CATEGORY=[^ ]*' | cut -d= -f2)
    FAILURE_ATTEMPT=$(echo "$FAILURE_INFO" | grep -o 'ATTEMPT=[^ ]*' | cut -d= -f2)

    build_restarts=$((build_restarts + 1))
    REMAINING=$(($(total_tasks) - $(count_passes)))
    log "Phase 2: Build stopped with $REMAINING remaining (exit=$BUILD_EXIT, category=$FAILURE_CAT, attempt=$FAILURE_ATTEMPT). Restarting..."

    if [ "${FAILURE_ATTEMPT:-1}" -ge 3 ]; then
      log "Phase 2: Build failing repeatedly (attempt $FAILURE_ATTEMPT). Flagging for review and continuing."
    fi

    sleep 5
  done

  # ─── PHASE 3: QA ───
  MAX_QA_RESTARTS=10
  qa_restarts=0

  while [ "$(qa_complete)" != "true" ] && [ "$qa_restarts" -lt "$MAX_QA_RESTARTS" ]; do
    qa_restarts=$((qa_restarts + 1))
    QA_SO_FAR=$($PY -c "import json; print(sum(1 for x in json.load(open('prd.json')) if x.get('qa_pass', False)))" 2>/dev/null || echo "0")
    log "Phase 3: Running QA... $QA_SO_FAR/$(total_tasks) passed (attempt $qa_restarts/$MAX_QA_RESTARTS)"

    PHASE_LOG_TMP=$(mktemp)
    QA_TIMEOUT=$(get_feature_timeout "")
    timeout "$QA_TIMEOUT" ./ralph/qa-ralph.sh "$TARGET_URL" 2>&1 | tee -a "$LOG_FILE" > "$PHASE_LOG_TMP" || true
    QA_EXIT=${PIPESTATUS[0]}
    LOG_TAIL=$(tail -80 "$PHASE_LOG_TMP" | tr "'" ' ')

    # Cost tracking
    COST_INFO=$(update_cost "qa" "qa_cycle_${cycle}" "$LOG_TAIL")
    BUDGET_CHECK=$(check_budget 2>&1 || true)
    if echo "$BUDGET_CHECK" | grep -q "BUDGET_ALERT"; then
      log "BUDGET WARNING: $BUDGET_CHECK"
    fi
    rm -f "$PHASE_LOG_TMP"

    # Analyze QA failure if not complete
    if [ "$(qa_complete)" != "true" ]; then
      FAILURE_INFO=$(analyze_failure "qa" "qa_cycle_${cycle}" "$QA_EXIT" "$LOG_TAIL")
      FAILURE_CAT=$(echo "$FAILURE_INFO" | grep -o 'FAILURE_CATEGORY=[^ ]*' | cut -d= -f2)
      FAILURE_ATTEMPT=$(echo "$FAILURE_INFO" | grep -o 'ATTEMPT=[^ ]*' | cut -d= -f2)
      log "Phase 3: QA attempt $qa_restarts incomplete (exit=$QA_EXIT, category=$FAILURE_CAT)"
      if [ "${FAILURE_ATTEMPT:-1}" -ge 3 ]; then
        log "Phase 3: QA failing repeatedly. Will flag features for human review."
      fi
    fi

    cron_backup
  done

  QA_STATUS=$(qa_complete)
  QA_PASSED=$($PY -c "import json; print(sum(1 for x in json.load(open('prd.json')) if x.get('qa_pass', False)))" 2>/dev/null || echo "0")
  TOTAL=$(total_tasks)

  if [ "$QA_STATUS" = "true" ] && all_passed; then
    log "=== ALL $TOTAL FEATURES: BUILT + QA VERIFIED ($QA_PASSED/$TOTAL qa_pass) ==="
    break
  fi

  log "Phase 3: Cycle $cycle done. QA passed: $QA_PASSED/$TOTAL. Build passes: $(count_passes)/$TOTAL."
  if [ "$QA_STATUS" != "true" ]; then
    log "Phase 3: QA incomplete — $(($TOTAL - $QA_PASSED)) features not qa_pass. Restarting QA..."
  else
    AFTER_QA=$(count_passes)
    REMAINING=$(($TOTAL - $AFTER_QA))
    log "Phase 3: QA found regressions — $REMAINING features need rebuild. Restarting build..."
  fi
done

cron_backup
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
HOURS=$(( ELAPSED / 3600 ))
MINUTES=$(( (ELAPSED % 3600) / 60 ))
SECONDS_LEFT=$(( ELAPSED % 60 ))
log ""
log "========================================="
log "  RALPH-TO-RALPH COMPLETE"
log "  Features: $(count_passes)/$(total_tasks) passed"
log "  QA Report: qa-report.json"
log "  End time: $(date '+%Y-%m-%d %H:%M:%S')"
log "  Duration: ${HOURS}h ${MINUTES}m ${SECONDS_LEFT}s"
log "  Cost Summary:"
print_cost_summary | while IFS= read -r line; do log "$line"; done
log "========================================="
