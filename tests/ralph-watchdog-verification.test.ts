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
    let exitCode = 0;
    try {
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
    } catch (error) {
      exitCode = (error as { status?: number }).status ?? 1;
    }

    const prd = JSON.parse(
      fs.readFileSync(path.join(tmpDir, "prd.json"), "utf8"),
    ) as Array<{ build_pass?: boolean; qa_pass?: boolean }>;
    const finalStatus = JSON.parse(
      fs.readFileSync(path.join(tmpDir, "ralph/final-status.json"), "utf8"),
    ) as { status: string };

    expect(exitCode).toBe(1);
    expect(finalStatus.status).toBe("BUILD_INCOMPLETE");
    expect(
      fs.readFileSync(path.join(tmpDir, ".build-invocations"), "utf8"),
    ).toBe("2");
    expect(fs.existsSync(path.join(tmpDir, ".qa-ran"))).toBe(false);
    expect(prd[0]?.build_pass).toBe(false);
    expect(prd[0]?.qa_pass).toBe(false);
  });

  it("stops with QA_STALLED after repeated zero-progress QA attempts", () => {
    fs.writeFileSync(
      path.join(tmpDir, "prd.json"),
      JSON.stringify(
        [
          {
            id: "feature-1",
            description: "Test feature",
            build_pass: true,
            qa_pass: false,
          },
        ],
        null,
        2,
      ),
    );

    fs.writeFileSync(
      path.join(tmpDir, "ralph/build-ralph.sh"),
      `#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
`,
      { mode: 0o755 },
    );

    fs.writeFileSync(
      path.join(tmpDir, "ralph/qa-ralph.sh"),
      `#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
count_file=".qa-invocations"
count=0
if [ -f "$count_file" ]; then
  count=$(cat "$count_file")
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"
exit 0
`,
      { mode: 0o755 },
    );

    let exitCode = 0;
    try {
      execFileSync("bash", ["ralph/ralph-watchdog.sh", "https://example.com"], {
        cwd: tmpDir,
        env: {
          ...process.env,
          MAX_CYCLES: "3",
          MAX_BUILD_RESTARTS: "1",
          MAX_QA_RESTARTS: "5",
          MAX_INSPECT_RESTARTS: "1",
          QA_STALL_THRESHOLD: "2",
          WATCHDOG_VERIFY_CHECK_CMD: "true",
          WATCHDOG_VERIFY_TEST_CMD: "true",
          WATCHDOG_VERIFY_BUILD_CMD: "true",
        },
        encoding: "utf8",
      });
    } catch (error) {
      exitCode = (error as { status?: number }).status ?? 1;
    }

    const qaInvocations = fs.readFileSync(
      path.join(tmpDir, ".qa-invocations"),
      "utf8",
    );
    const log = fs.readFileSync(
      path.join(tmpDir, fs.readdirSync(tmpDir).find((f) => f.startsWith("ralph-watchdog-") && f.endsWith(".log"))!),
      "utf8",
    );
    const finalStatus = JSON.parse(
      fs.readFileSync(path.join(tmpDir, "ralph/final-status.json"), "utf8"),
    ) as {
      status: string;
      counts: { build_passed: number; qa_passed: number; blocked: number };
    };
    const prd = JSON.parse(
      fs.readFileSync(path.join(tmpDir, "prd.json"), "utf8"),
    ) as Array<{ build_pass?: boolean; qa_pass?: boolean }>;

    expect(exitCode).toBe(1);
    expect(qaInvocations).toBe("2");
    expect(log).toContain("QA_STALLED");
    expect(log).toContain("RALPH-TO-RALPH QA_STALLED");
    expect(log).toContain("Stopping honestly instead of relaunching QA with no forward motion.");
    expect(finalStatus.status).toBe("QA_STALLED");
    expect(finalStatus.counts.build_passed).toBe(1);
    expect(finalStatus.counts.qa_passed).toBe(0);
    expect(finalStatus.counts.blocked).toBe(1);
    expect(prd[0]?.build_pass).toBe(true);
    expect(prd[0]?.qa_pass).toBe(false);
  });

  it("reports INCOMPLETE_QA instead of a fake success footer when build finishes but QA does not", () => {
    fs.writeFileSync(
      path.join(tmpDir, "prd.json"),
      JSON.stringify(
        [
          {
            id: "feature-1",
            description: "Test feature",
            build_pass: true,
            qa_pass: false,
          },
        ],
        null,
        2,
      ),
    );

    fs.writeFileSync(
      path.join(tmpDir, "ralph/build-ralph.sh"),
      `#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
`,
      { mode: 0o755 },
    );

    fs.writeFileSync(
      path.join(tmpDir, "ralph/qa-ralph.sh"),
      `#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exit 0
`,
      { mode: 0o755 },
    );

    let exitCode = 0;
    try {
      execFileSync("bash", ["ralph/ralph-watchdog.sh", "https://example.com"], {
        cwd: tmpDir,
        env: {
          ...process.env,
          MAX_CYCLES: "1",
          MAX_BUILD_RESTARTS: "1",
          MAX_QA_RESTARTS: "1",
          MAX_INSPECT_RESTARTS: "1",
          QA_STALL_THRESHOLD: "99",
          WATCHDOG_VERIFY_CHECK_CMD: "true",
          WATCHDOG_VERIFY_TEST_CMD: "true",
          WATCHDOG_VERIFY_BUILD_CMD: "true",
        },
        encoding: "utf8",
      });
    } catch (error) {
      exitCode = (error as { status?: number }).status ?? 1;
    }

    const log = fs.readFileSync(
      path.join(tmpDir, fs.readdirSync(tmpDir).find((f) => f.startsWith("ralph-watchdog-") && f.endsWith(".log"))!),
      "utf8",
    );
    const finalStatus = JSON.parse(
      fs.readFileSync(path.join(tmpDir, "ralph/final-status.json"), "utf8"),
    ) as {
      status: string;
      counts: { build_passed: number; qa_passed: number; blocked: number };
    };

    expect(exitCode).toBe(1);
    expect(log).toContain("RALPH-TO-RALPH INCOMPLETE_QA");
    expect(log).not.toContain("RALPH-TO-RALPH COMPLETE");
    expect(finalStatus.status).toBe("INCOMPLETE_QA");
    expect(finalStatus.counts.build_passed).toBe(1);
    expect(finalStatus.counts.qa_passed).toBe(0);
    expect(finalStatus.counts.blocked).toBe(1);
  });
});
