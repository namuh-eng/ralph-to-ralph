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

# Global time budget (hours) — prevents unbounded runs
MAX_WALL_CLOCK_HOURS="${MAX_WALL_CLOCK_HOURS:-12}"
START_EPOCH=$(date +%s)

# Resolve Python: prefer `uv run python3` if uv is available, fall back to bare python3
if command -v uv &>/dev/null; then
  PY="uv run python3"
else
  PY="python3"
fi

check_time_budget() {
  local now=$(date +%s)
  local max_seconds=$(( MAX_WALL_CLOCK_HOURS * 3600 ))
  local elapsed=$(( now - START_EPOCH ))
  if [ "$elapsed" -ge "$max_seconds" ]; then
    local elapsed_hours=$(( elapsed / 3600 ))
    log "TIME BUDGET EXHAUSTED (${elapsed_hours}h >= ${MAX_WALL_CLOCK_HOURS}h limit)."
    log "Build: $(count_passes)/$(total_tasks) | QA: $($PY -c "import json; print(sum(1 for x in json.load(open('prd.json')) if x.get('qa_pass', False)))" 2>/dev/null || echo '?')/$(total_tasks)"
    log "Increase MAX_WALL_CLOCK_HOURS env var to allow more time."
    exit 2  # time budget exhausted, work incomplete
  fi
}

run_watchdog_command() {
  local label="$1"
  local command="$2"

  if [ -z "$command" ]; then
    log "Phase 2: Skipping $label verification (empty command)."
    return 0
  fi

  log "Phase 2: Verifying workspace via $label: $command"
  bash -lc "$command" >> "$LOG_FILE" 2>&1
  local exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    log "Phase 2: Verification passed for $label."
    return 0
  fi

  log "Phase 2: Verification failed for $label (exit=$exit_code)."
  return "$exit_code"
}

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
import json
try:
    cfg = json.load(open('ralph-config.json'))
    print(cfg.get('maxBudget', 0))
except Exception:
    print(0)
" 2>/dev/null || echo "0")

init_cost_log() {
  if [ ! -f "$COST_LOG" ]; then
    _WD_COST_LOG="$COST_LOG" _WD_BUDGET="$COST_BUDGET" $PY - <<'PY'
import json, os
data = {
    "total_cost_usd": 0.0,
    "total_input_tokens": 0,
    "total_output_tokens": 0,
    "budget_usd": float(os.environ.get("_WD_BUDGET", "0")),
    "entries": []
}
with open(os.environ["_WD_COST_LOG"], "w") as f:
    json.dump(data, f, indent=2)
PY
  fi
}

update_cost() {
  local phase="$1"
  local feature="${2:-unknown}"
  local log_snippet="$3"

  _WD_PHASE="$phase" _WD_FEATURE="$feature" _WD_LOG="$log_snippet" \
  _WD_COST_LOG="$COST_LOG" _WD_BUDGET="$COST_BUDGET" \
  $PY - 2>/dev/null <<'PY' || true
import json, re, os
from datetime import datetime

phase = os.environ["_WD_PHASE"]
feature = os.environ["_WD_FEATURE"]
log_text = os.environ["_WD_LOG"]
cost_log = os.environ["_WD_COST_LOG"]
budget = float(os.environ.get("_WD_BUDGET", "0"))

input_tokens = 0
output_tokens = 0

for pat in [r'input[_ ]tokens?[:\s]+([0-9,]+)', r'"input_tokens":\s*([0-9]+)', r'Input:\s*([0-9,]+)\s*tokens']:
    m = re.search(pat, log_text, re.IGNORECASE)
    if m:
        input_tokens = int(m.group(1).replace(",", ""))
        break

for pat in [r'output[_ ]tokens?[:\s]+([0-9,]+)', r'"output_tokens":\s*([0-9]+)', r'Output:\s*([0-9,]+)\s*tokens']:
    m = re.search(pat, log_text, re.IGNORECASE)
    if m:
        output_tokens = int(m.group(1).replace(",", ""))
        break

cost_usd = (input_tokens / 1_000_000) * 15.0 + (output_tokens / 1_000_000) * 75.0

try:
    with open(cost_log) as f:
        data = json.load(f)
except Exception:
    data = {"total_cost_usd": 0.0, "total_input_tokens": 0, "total_output_tokens": 0, "budget_usd": budget, "entries": []}

data["total_cost_usd"] += cost_usd
data["total_input_tokens"] += input_tokens
data["total_output_tokens"] += output_tokens
data["entries"].append({
    "timestamp": datetime.utcnow().isoformat(),
    "phase": phase,
    "feature": feature,
    "input_tokens": input_tokens,
    "output_tokens": output_tokens,
    "cost_usd": round(cost_usd, 6)
})

with open(cost_log, "w") as f:
    json.dump(data, f, indent=2)

total = data["total_cost_usd"]
print(f"COST_UPDATE total={total:.4f} budget={budget}")
PY
}

check_budget() {
  if [ "$COST_BUDGET" = "0" ] || [ -z "$COST_BUDGET" ]; then
    return 0
  fi

  local budget_output=""
  local budget_status=0
  budget_output=$(_WD_COST_LOG="$COST_LOG" $PY - 2>/dev/null <<'PY'
import json, sys, os

try:
    data = json.load(open(os.environ["_WD_COST_LOG"]))
except Exception:
    sys.exit(0)

total = data.get("total_cost_usd", 0.0)
budget = data.get("budget_usd", 0.0)
if budget <= 0:
    sys.exit(0)

pct = (total / budget) * 100

if pct >= 100:
    print(f"BUDGET_EXCEEDED total=${total:.4f} budget=${budget:.2f}")
    sys.exit(2)
elif pct >= 90:
    print(f"BUDGET_ALERT_90 {pct:.1f}% used (${total:.4f}/${budget:.2f})")
elif pct >= 75:
    print(f"BUDGET_ALERT_75 {pct:.1f}% used (${total:.4f}/${budget:.2f})")
elif pct >= 50:
    print(f"BUDGET_ALERT_50 {pct:.1f}% used (${total:.4f}/${budget:.2f})")
PY
  ) || budget_status=$?

  [ -n "$budget_output" ] && echo "$budget_output"

  if [ "$budget_status" -eq 2 ]; then
    log "BUDGET EXCEEDED — stopping. See $COST_LOG for details."
    print_cost_summary
    exit 1
  fi
}

print_cost_summary() {
  _WD_COST_LOG="$COST_LOG" $PY - 2>/dev/null <<'PY' || true
import json, os
try:
    data = json.load(open(os.environ["_WD_COST_LOG"]))
    total = data.get("total_cost_usd", 0.0)
    budget = data.get("budget_usd", 0.0)
    inp = data.get("total_input_tokens", 0)
    out = data.get("total_output_tokens", 0)
    print(f"  Total cost: ${total:.4f}")
    if budget > 0:
        pct = (total / budget) * 100
        print(f"  Budget: ${budget:.2f} ({pct:.1f}% used)")
    print(f"  Tokens: {inp:,} input / {out:,} output")
    entries = data.get("entries", [])
    if entries:
        by_phase = {}
        for e in entries:
            ph = e.get("phase", "unknown")
            by_phase[ph] = by_phase.get(ph, 0.0) + e.get("cost_usd", 0.0)
        print("  Cost by phase:")
        for ph, cost in sorted(by_phase.items(), key=lambda x: -x[1]):
            print(f"    {ph}: ${cost:.4f}")
except Exception as ex:
    print(f"  (cost log unavailable: {ex})")
PY
}

# ─── Failure Analysis ───

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

  _WD_PHASE="$phase" _WD_FEATURE="$feature" _WD_EXIT="$exit_code" \
  _WD_LOG="$log_tail" _WD_FAILURE_LOG="$FAILURE_LOG" \
  $PY - 2>/dev/null <<'PY' || echo "FAILURE_CATEGORY=unknown ATTEMPT=1"
import json, re, os
from datetime import datetime

phase = os.environ["_WD_PHASE"]
feature = os.environ["_WD_FEATURE"]
exit_code = int(os.environ["_WD_EXIT"])
log_text = os.environ["_WD_LOG"]
failure_log = os.environ["_WD_FAILURE_LOG"]

category = "unknown"

if exit_code == 124 or "timeout" in log_text.lower() or "timed out" in log_text.lower():
    category = "timeout"
elif re.search(r"context.{0,20}(overflow|limit|too long|window)", log_text, re.IGNORECASE):
    category = "context_overflow"
elif re.search(r"(rate.?limit|429|too many requests|quota)", log_text, re.IGNORECASE):
    category = "api_error"
elif re.search(r"(compilation.?fail|type.?error|build.?fail|tsc|typescript)", log_text, re.IGNORECASE):
    category = "compilation_failure"
elif re.search(r"(test.?fail|assertion|expect.*received|FAIL|playwright)", log_text, re.IGNORECASE):
    category = "test_failure"
elif re.search(r"(api.?error|network|connection|ECONNREFUSED)", log_text, re.IGNORECASE):
    category = "api_error"

try:
    with open(failure_log) as f:
        data = json.load(f)
except Exception:
    data = {"failures": []}

prior = sum(1 for e in data["failures"]
            if e.get("feature") == feature and e.get("phase") == phase)

data["failures"].append({
    "timestamp": datetime.utcnow().isoformat(),
    "phase": phase,
    "feature": feature,
    "exit_code": exit_code,
    "category": category,
    "attempt": prior + 1
})

with open(failure_log, "w") as f:
    json.dump(data, f, indent=2)

print(f"FAILURE_CATEGORY={category} ATTEMPT={prior + 1}")
PY
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

reset_pass_flags() {
  local reset_counts
  reset_counts=$($PY -c "
import json

with open('prd.json') as f:
    prd = json.load(f)

build_reset = 0
qa_reset = 0
for item in prd:
    if item.get('build_pass', False):
        build_reset += 1
    if item.get('qa_pass', False):
        qa_reset += 1
    item['build_pass'] = False
    item['qa_pass'] = False

with open('prd.json', 'w') as f:
    json.dump(prd, f, indent=2)

print(f'{build_reset}:{qa_reset}')
" 2>/dev/null || echo "0:0")

  log "Phase 2: Reset stale pass flags (build_pass=${reset_counts%%:*}, qa_pass=${reset_counts##*:})."
}

verify_workspace_contract() {
  local check_cmd="${WATCHDOG_VERIFY_CHECK_CMD:-make check}"
  local test_cmd="${WATCHDOG_VERIFY_TEST_CMD:-make test}"
  local build_cmd="${WATCHDOG_VERIFY_BUILD_CMD:-make build}"
  local docker_cmd="${WATCHDOG_VERIFY_DOCKER_CMD:-docker build .}"

  run_watchdog_command "check" "$check_cmd" || return 1
  run_watchdog_command "test" "$test_cmd" || return 1
  run_watchdog_command "build" "$build_cmd" || return 1

  if [ -f "Dockerfile" ]; then
    run_watchdog_command "docker" "$docker_cmd" || return 1
  else
    log "Phase 2: Skipping docker verification (no Dockerfile)."
  fi
}

inspect_done() {
  [ -f ".inspect-complete" ]
}

cron_backup() {
  git add -A 2>/dev/null
  git commit -m "watchdog backup $(date '+%H:%M') — $(count_passes)/$(total_tasks) passes" 2>/dev/null || true
  git push 2>/dev/null || true
}

# ─── Init ───

START_TIME=$(date +%s)
log "=== Ralph-to-Ralph Watchdog Started ==="
log "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Target: $TARGET_URL"
if [ "$COST_BUDGET" != "0" ] && [ -n "$COST_BUDGET" ]; then
  log "Budget: \$$COST_BUDGET"
fi

init_cost_log
init_failure_log

# ─── PHASE 1: Inspect ───

MAX_INSPECT_RESTARTS="${MAX_INSPECT_RESTARTS:-5}"
inspect_restarts=0

while ! inspect_done; do
  if [ "$inspect_restarts" -ge "$MAX_INSPECT_RESTARTS" ]; then
    log "Phase 1: Hit max restarts ($MAX_INSPECT_RESTARTS). Aborting."
    exit 1
  fi

  check_time_budget
  log "Phase 1: Running inspect loop... (attempt $((inspect_restarts + 1)))"

  PHASE_LOG_TMP=$(mktemp)
  ./ralph/inspect-ralph.sh "$TARGET_URL" 2>&1 | tee -a "$LOG_FILE" > "$PHASE_LOG_TMP" || true
  INSPECT_EXIT=${PIPESTATUS[0]}
  LOG_TAIL=$(tail -50 "$PHASE_LOG_TMP")

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
    FAILURE_INFO=$(analyze_failure "inspect" "inspect" "$INSPECT_EXIT" "$LOG_TAIL")
    FAILURE_CAT=$(echo "$FAILURE_INFO" | grep -o 'FAILURE_CATEGORY=[^ ]*' | cut -d= -f2)
    log "Phase 1: Inspect stopped (exit=$INSPECT_EXIT, category=$FAILURE_CAT). Restarting..."

    inspect_restarts=$((inspect_restarts + 1))
    sleep 5
  fi
done

# ─── PHASE 2 + 3: Build → QA → Fix loop ───

MAX_CYCLES="${MAX_CYCLES:-5}"
for ((cycle=1; cycle<=MAX_CYCLES; cycle++)); do
  log ""
  log "===== CYCLE $cycle/$MAX_CYCLES ====="

  check_budget

  # ─── PHASE 2: Build ───
  MAX_BUILD_RESTARTS="${MAX_BUILD_RESTARTS:-10}"
  build_restarts=0

  while ! all_passed; do
    if [ "$build_restarts" -ge "$MAX_BUILD_RESTARTS" ]; then
      log "Phase 2: Hit max restarts ($MAX_BUILD_RESTARTS). Moving to QA."
      break
    fi

    check_time_budget
    log "Phase 2: Building... $(count_passes)/$(total_tasks) passes (attempt $((build_restarts + 1)))"

    PHASE_LOG_TMP=$(mktemp)
    ./ralph/build-ralph.sh 2>&1 | tee -a "$LOG_FILE" > "$PHASE_LOG_TMP" || true
    BUILD_EXIT=${PIPESTATUS[0]}
    LOG_TAIL=$(tail -80 "$PHASE_LOG_TMP")

    COST_INFO=$(update_cost "build" "build_cycle_${cycle}" "$LOG_TAIL")
    BUDGET_CHECK=$(check_budget 2>&1 || true)
    if echo "$BUDGET_CHECK" | grep -q "BUDGET_ALERT"; then
      log "BUDGET WARNING: $BUDGET_CHECK"
    fi
    rm -f "$PHASE_LOG_TMP"

    cron_backup

    if all_passed; then
      log "Phase 2: All $(total_tasks) features report build_pass."
      break
    fi

    FAILURE_INFO=$(analyze_failure "build" "build_cycle_${cycle}" "$BUILD_EXIT" "$LOG_TAIL")
    FAILURE_CAT=$(echo "$FAILURE_INFO" | grep -o 'FAILURE_CATEGORY=[^ ]*' | cut -d= -f2)
    FAILURE_ATTEMPT=$(echo "$FAILURE_INFO" | grep -o 'ATTEMPT=[^ ]*' | cut -d= -f2)

    build_restarts=$((build_restarts + 1))
    REMAINING=$(($(total_tasks) - $(count_passes)))
    log "Phase 2: Build stopped with $REMAINING remaining (exit=$BUILD_EXIT, category=$FAILURE_CAT, attempt=$FAILURE_ATTEMPT). Restarting..."

    if [ "${FAILURE_ATTEMPT:-1}" -ge 3 ]; then
      log "Phase 2: Build failing repeatedly (attempt $FAILURE_ATTEMPT)."
    fi

    sleep 5
  done

  if ! all_passed; then
    REMAINING=$(($(total_tasks) - $(count_passes)))
    log "Phase 2: Build incomplete after restarts — $REMAINING features still need build_pass. Skipping QA for this cycle."
    continue
  fi

  if ! verify_workspace_contract; then
    log "Phase 2: Independent verification failed. Resetting stale pass flags and returning to build next cycle."
    reset_pass_flags
    cron_backup
    continue
  fi

  # ─── PHASE 3: QA ───
  MAX_QA_RESTARTS="${MAX_QA_RESTARTS:-10}"
  qa_restarts=0

  while [ "$(qa_complete)" != "true" ] && [ "$qa_restarts" -lt "$MAX_QA_RESTARTS" ]; do
    qa_restarts=$((qa_restarts + 1))
    QA_SO_FAR=$($PY -c "import json; print(sum(1 for x in json.load(open('prd.json')) if x.get('qa_pass', False)))" 2>/dev/null || echo "0")
    check_time_budget
    log "Phase 3: Running QA... $QA_SO_FAR/$(total_tasks) passed (attempt $qa_restarts/$MAX_QA_RESTARTS)"

    PHASE_LOG_TMP=$(mktemp)
    ./ralph/qa-ralph.sh "$TARGET_URL" 2>&1 | tee -a "$LOG_FILE" > "$PHASE_LOG_TMP" || true
    QA_EXIT=${PIPESTATUS[0]}
    LOG_TAIL=$(tail -80 "$PHASE_LOG_TMP")

    COST_INFO=$(update_cost "qa" "qa_cycle_${cycle}" "$LOG_TAIL")
    BUDGET_CHECK=$(check_budget 2>&1 || true)
    if echo "$BUDGET_CHECK" | grep -q "BUDGET_ALERT"; then
      log "BUDGET WARNING: $BUDGET_CHECK"
    fi
    rm -f "$PHASE_LOG_TMP"

    if [ "$(qa_complete)" != "true" ]; then
      FAILURE_INFO=$(analyze_failure "qa" "qa_cycle_${cycle}" "$QA_EXIT" "$LOG_TAIL")
      FAILURE_CAT=$(echo "$FAILURE_INFO" | grep -o 'FAILURE_CATEGORY=[^ ]*' | cut -d= -f2)
      FAILURE_ATTEMPT=$(echo "$FAILURE_INFO" | grep -o 'ATTEMPT=[^ ]*' | cut -d= -f2)
      log "Phase 3: QA attempt $qa_restarts incomplete (exit=$QA_EXIT, category=$FAILURE_CAT)"
      if [ "${FAILURE_ATTEMPT:-1}" -ge 3 ]; then
        log "Phase 3: QA failing repeatedly (attempt $FAILURE_ATTEMPT)."
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
