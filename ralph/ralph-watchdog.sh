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

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

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
_BROWSER_AGENT=$(python3 -c "import json; print(json.load(open('ralph-config.json')).get('browserAgent', 'ever'))" 2>/dev/null || echo "ever")
if [ "$_BROWSER_AGENT" = "ever" ]; then
  trap 'rm -f "$LOCKFILE"; ever stop 2>/dev/null' EXIT
else
  trap 'rm -f "$LOCKFILE"' EXIT
fi

# ─── Helpers ───

count_passes() {
  python3 -c "
import json; d=json.load(open('prd.json'))
print(sum(1 for x in d if x.get('build_pass', False)))
" 2>/dev/null || echo "0"
}

total_tasks() {
  python3 -c "import json; print(len(json.load(open('prd.json'))))" 2>/dev/null || echo "0"
}

all_passed() {
  local total=$(total_tasks)
  local passed=$(count_passes)
  [ "$total" -gt 0 ] && [ "$passed" -ge "$total" ]
}

qa_complete() {
  python3 -c "
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

# ─── PHASE 1: Inspect ───

START_TIME=$(date +%s)
log "=== Ralph-to-Ralph Watchdog Started ==="
log "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Target: $TARGET_URL"

MAX_INSPECT_RESTARTS=5
inspect_restarts=0

while ! inspect_done; do
  if [ "$inspect_restarts" -ge "$MAX_INSPECT_RESTARTS" ]; then
    log "Phase 1: Hit max restarts ($MAX_INSPECT_RESTARTS). Aborting."
    exit 1
  fi

  log "Phase 1: Running inspect loop... (attempt $((inspect_restarts + 1)))"
  ./ralph/inspect-ralph.sh "$TARGET_URL" || true
  cron_backup

  if inspect_done; then
    log "Phase 1: Complete! $(total_tasks) features found."
    break
  else
    inspect_restarts=$((inspect_restarts + 1))
    log "Phase 1: Inspect stopped but not complete. Restarting..."
    sleep 5
  fi
done

# ─── PHASE 2 + 3: Build → QA → Fix loop ───

MAX_CYCLES=5
for ((cycle=1; cycle<=MAX_CYCLES; cycle++)); do
  log ""
  log "===== CYCLE $cycle/$MAX_CYCLES ====="

  # ─── PHASE 2: Build ───
  MAX_BUILD_RESTARTS=10
  build_restarts=0

  while ! all_passed; do
    if [ "$build_restarts" -ge "$MAX_BUILD_RESTARTS" ]; then
      log "Phase 2: Hit max restarts ($MAX_BUILD_RESTARTS). Moving to QA."
      break
    fi

    log "Phase 2: Building... $(count_passes)/$(total_tasks) passes (attempt $((build_restarts + 1)))"
    ./ralph/build-ralph.sh || true
    cron_backup

    if all_passed; then
      log "Phase 2: All $(total_tasks) features pass!"
      break
    fi

    build_restarts=$((build_restarts + 1))
    REMAINING=$(($(total_tasks) - $(count_passes)))
    log "Phase 2: Build stopped with $REMAINING remaining. Restarting..."
    sleep 5
  done

  # ─── PHASE 3: QA ───
  log "Phase 3: Starting QA..."
  ./ralph/qa-ralph.sh "$TARGET_URL" || true
  cron_backup

  QA_STATUS=$(qa_complete)
  QA_PASSED=$(python3 -c "import json; print(sum(1 for x in json.load(open('prd.json')) if x.get('qa_pass', False)))" 2>/dev/null || echo "0")
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
log "========================================="
