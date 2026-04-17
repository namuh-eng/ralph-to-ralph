#!/bin/bash
# Generate demo API keys for hackathon distribution
# Usage: ./scripts/generate-demo-keys.sh [count] [api-url]
set -euo pipefail

COUNT="${1:-20}"
API_URL="${2:-http://127.0.0.1:3002}"
MASTER_KEY="${DASHBOARD_KEY:-re_dev_token_123}"

# Resolve Python: prefer `uv run python3` if uv is available, fall back to bare python3
if command -v uv &>/dev/null; then
  PY="uv run python3"
else
  PY="python3"
fi

echo "=== Generating $COUNT demo API keys ==="
echo "API: $API_URL"
echo ""
echo "Key,Name,Permission"

for i in $(seq 1 $COUNT); do
  NAME="demo-$i"
  RESULT=$(node -e "
    fetch('${API_URL}/api/api-keys', {
      method: 'POST',
      headers: {'Content-Type':'application/json','Authorization':'Bearer ${MASTER_KEY}'},
      body: JSON.stringify({name:'${NAME}',permission:'full_access'})
    }).then(r=>r.json()).then(d=>console.log(JSON.stringify(d))).catch(e=>console.error(e))
  " 2>&1)

  TOKEN=$(echo "$RESULT" | $PY -c "import json,sys; d=json.load(sys.stdin); print(d.get('token','ERROR'))" 2>/dev/null || echo "ERROR")

  if [ "$TOKEN" != "ERROR" ]; then
    echo "$TOKEN,$NAME,full_access"
  else
    echo "FAILED,$NAME,error: $RESULT"
  fi
done

echo ""
echo "=== Done. Distribute keys to demo attendees. ==="
echo "Each key unlocks both the dashboard AND the API."
