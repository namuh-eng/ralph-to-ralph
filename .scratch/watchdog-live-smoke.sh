#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

LOG_DIR=".scratch/logs"
mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/watchdog-live-smoke.log"

cat <<'EOF_INPUT' | \
  env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL \
  MAX_CYCLES=1 \
  MAX_BUILD_RESTARTS=1 \
  MAX_QA_RESTARTS=1 \
  MAX_INSPECT_RESTARTS=1 \
  MAX_WALL_CLOCK_HOURS=1 \
  timeout 1200 ./ralph/onboard.sh 2>&1 | tee "$RUN_LOG"
2
https://example.com
example-watchdog-smoke
2
5
Local-only Next.js clone for watchdog smoke testing with local Postgres config and no external cloud deployment.
1
n
1
1
y
EOF_INPUT
