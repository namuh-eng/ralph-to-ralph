#!/bin/bash
# ABOUTME: Regression test for the watchdog's independent build verification gate.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

assert_file_exists() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "expected file to exist: $path" >&2
    exit 1
  fi
}

assert_file_not_exists() {
  local path="$1"
  if [ -f "$path" ]; then
    echo "expected file to be absent: $path" >&2
    exit 1
  fi
}

assert_json_field_equals() {
  local path="$1"
  local field="$2"
  local expected="$3"

  local actual
  actual="$(python3 - "$path" "$field" <<'PY'
import json, sys
path, field = sys.argv[1], sys.argv[2]
value = json.load(open(path))[0]
for part in field.split("."):
    value = value[part]
print(str(value).lower() if isinstance(value, bool) else value)
PY
)"

  if [ "$actual" != "$expected" ]; then
    echo "expected $field in $path to be $expected, got $actual" >&2
    exit 1
  fi
}

mkdir -p "$TMP_DIR/ralph" "$TMP_DIR/bin"
cp "$REPO_ROOT/ralph/ralph-watchdog.sh" "$TMP_DIR/ralph/ralph-watchdog.sh"
chmod +x "$TMP_DIR/ralph/ralph-watchdog.sh"

cat > "$TMP_DIR/prd.json" <<'EOF'
[
  {
    "id": "feature-1",
    "description": "Stub feature",
    "build_pass": true,
    "qa_pass": false
  }
]
EOF

cat > "$TMP_DIR/ralph-config.json" <<'EOF'
{
  "browserAgent": "custom",
  "maxBudget": 0
}
EOF

touch "$TMP_DIR/.inspect-complete"

cat > "$TMP_DIR/ralph/inspect-ralph.sh" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$TMP_DIR/ralph/build-ralph.sh" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$TMP_DIR/ralph/qa-ralph.sh" <<'EOF'
#!/bin/bash
cd "$(dirname "$0")/.."
touch qa-ran
python3 - <<'PY'
import json
with open("prd.json") as f:
    data = json.load(f)
data[0]["qa_pass"] = True
with open("prd.json", "w") as f:
    json.dump(data, f, indent=2)
PY
exit 0
EOF

chmod +x "$TMP_DIR/ralph/inspect-ralph.sh" "$TMP_DIR/ralph/build-ralph.sh" "$TMP_DIR/ralph/qa-ralph.sh"

cat > "$TMP_DIR/bin/fail-check.sh" <<'EOF'
#!/bin/bash
cd "$(dirname "$0")/.."
touch make-called
exit 1
EOF

chmod +x "$TMP_DIR/bin/fail-check.sh"

(
  cd "$TMP_DIR"
  PATH="$TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  MAX_CYCLES=1 \
  WATCHDOG_VERIFY_CHECK_CMD="$TMP_DIR/bin/fail-check.sh" \
  WATCHDOG_VERIFY_TEST_CMD=":" \
  WATCHDOG_VERIFY_BUILD_CMD=":" \
  WATCHDOG_VERIFY_DOCKER_CMD=":" \
  ./ralph/ralph-watchdog.sh "https://example.com" >/dev/null 2>&1 || true
)

assert_file_exists "$TMP_DIR/make-called"
assert_file_not_exists "$TMP_DIR/qa-ran"
assert_json_field_equals "$TMP_DIR/prd.json" "build_pass" "false"
assert_json_field_equals "$TMP_DIR/prd.json" "qa_pass" "false"

echo "watchdog verification gate test passed"
