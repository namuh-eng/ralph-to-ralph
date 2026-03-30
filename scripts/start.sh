#!/bin/bash
# Start the Ralph-to-Ralph cloning loop
# Usage: ./scripts/start.sh <target-url>
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_URL="${1:?Usage: $0 <target-url>}"

echo "=== Ralph-to-Ralph ==="
echo "Target: $TARGET_URL"
echo ""

# Kill existing watchdog if running
if [ -f ".ralph-watchdog.lock" ]; then
  PID=$(cat .ralph-watchdog.lock 2>/dev/null)
  if kill -0 "$PID" 2>/dev/null; then
    echo "Stopping existing watchdog (PID $PID)..."
    kill "$PID" 2>/dev/null || true
    sleep 2
  fi
  rm -f .ralph-watchdog.lock
fi

# Initialize state files
echo '[]' > prd.json
touch build-progress.txt inspect-progress.txt
echo '[]' > qa-report.json

echo "Starting watchdog..."
echo "=================================="
./ralph-watchdog.sh "$TARGET_URL"
