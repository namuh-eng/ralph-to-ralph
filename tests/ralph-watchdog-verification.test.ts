// ABOUTME: Regression test for the watchdog's independent verification gate
// Ensures failed workspace verification resets stale pass flags and skips QA

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");

describe("ralph-watchdog verification gate", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "watchdog-test-"));
    fs.mkdirSync(path.join(tmpDir, "ralph"), { recursive: true });

    execFileSync("git", ["init"], { cwd: tmpDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test User"], {
      cwd: tmpDir,
      stdio: "ignore",
    });
    execFileSync("git", ["config", "user.email", "test@example.com"], {
      cwd: tmpDir,
      stdio: "ignore",
    });

    fs.copyFileSync(
      path.join(repoRoot, "ralph/ralph-watchdog.sh"),
      path.join(tmpDir, "ralph/ralph-watchdog.sh"),
    );

    fs.writeFileSync(
      path.join(tmpDir, "ralph-config.json"),
      JSON.stringify({ browserAgent: "none" }),
    );

    fs.writeFileSync(
      path.join(tmpDir, "prd.json"),
      JSON.stringify(
        [
          {
            id: "feature-1",
            description: "Test feature",
            build_pass: false,
            qa_pass: true,
          },
        ],
        null,
        2,
      ),
    );

    fs.writeFileSync(
      path.join(tmpDir, "ralph/inspect-ralph.sh"),
      `#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
touch .inspect-complete
`,
      { mode: 0o755 },
    );

    fs.writeFileSync(
      path.join(tmpDir, "ralph/build-ralph.sh"),
      `#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
count_file=".build-invocations"
count=0
if [ -f "$count_file" ]; then
  count=$(cat "$count_file")
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"
python3 - <<'PY'
import json
with open("prd.json") as f:
    prd = json.load(f)
for item in prd:
    item["build_pass"] = True
    item["qa_pass"] = True
with open("prd.json", "w") as f:
    json.dump(prd, f, indent=2)
PY
`,
      { mode: 0o755 },
    );

    fs.writeFileSync(
      path.join(tmpDir, "ralph/qa-ralph.sh"),
      `#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
touch .qa-ran
`,
      { mode: 0o755 },
    );
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it("resets stale flags and returns to build instead of starting QA when verification fails", () => {
    execFileSync("bash", ["ralph/ralph-watchdog.sh", "https://example.com"], {
      cwd: tmpDir,
      env: {
        ...process.env,
        MAX_CYCLES: "2",
        MAX_BUILD_RESTARTS: "1",
        MAX_QA_RESTARTS: "1",
        MAX_INSPECT_RESTARTS: "1",
        WATCHDOG_VERIFY_CHECK_CMD: "true",
        WATCHDOG_VERIFY_TEST_CMD: "false",
        WATCHDOG_VERIFY_BUILD_CMD: "true",
      },
      encoding: "utf8",
    });

    const prd = JSON.parse(
      fs.readFileSync(path.join(tmpDir, "prd.json"), "utf8"),
    ) as Array<{ build_pass?: boolean; qa_pass?: boolean }>;

    expect(
      fs.readFileSync(path.join(tmpDir, ".build-invocations"), "utf8"),
    ).toBe("2");
    expect(fs.existsSync(path.join(tmpDir, ".qa-ran"))).toBe(false);
    expect(prd[0]?.build_pass).toBe(false);
    expect(prd[0]?.qa_pass).toBe(false);
  });
});
