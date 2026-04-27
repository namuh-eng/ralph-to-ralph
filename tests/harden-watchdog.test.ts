// ABOUTME: Regression tests for the production harden watchdog loop
// Ensures hardening phases produce durable state and stop honestly when blocked

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");

describe("harden-watchdog", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "harden-watchdog-test-"));
    fs.mkdirSync(path.join(tmpDir, "ralph"), { recursive: true });
    fs.copyFileSync(
      path.join(repoRoot, "ralph/harden-watchdog.sh"),
      path.join(tmpDir, "ralph/harden-watchdog.sh"),
    );
    fs.chmodSync(path.join(tmpDir, "ralph/harden-watchdog.sh"), 0o755);
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it("seeds audit gaps, verifies them, and writes learnings", () => {
    fs.writeFileSync(
      path.join(tmpDir, "ralph/production-checklist.json"),
      JSON.stringify(
        [
          {
            id: "gap-test",
            kind: "infra",
            severity: "low",
            summary: "Test gap",
            description: "A test hardening gap",
            verifier: "true",
          },
        ],
        null,
        2,
      ),
    );

    execFileSync("bash", ["ralph/harden-watchdog.sh", "https://example.com"], {
      cwd: tmpDir,
      env: { ...process.env, HARDEN_MAX_RETRIES: "1", CANARY_COMMAND: "true" },
      encoding: "utf8",
    });

    const gaps = JSON.parse(
      fs.readFileSync(path.join(tmpDir, "ralph/harden-gap.json"), "utf8"),
    ) as Array<{ passes?: boolean; last_verified_by?: string }>;
    const learnings = fs.readFileSync(
      path.join(tmpDir, "ralph/harden-learnings.md"),
      "utf8",
    );

    expect(gaps[0]?.passes).toBe(true);
    expect(gaps[0]?.last_verified_by).toBe("true");
    expect(learnings).toContain("Passed gaps: 1");
    expect(learnings).toContain("gap-test");
  });

  it("exits with an exact blocker when a verifier fails", () => {
    fs.writeFileSync(
      path.join(tmpDir, "ralph/production-checklist.json"),
      JSON.stringify(
        [
          {
            id: "gap-failing",
            kind: "reliability",
            severity: "high",
            summary: "Failing gap",
            description: "A gap with a failing verifier",
            verifier: "false",
          },
        ],
        null,
        2,
      ),
    );

    let output = "";
    let exitCode = 0;
    try {
      execFileSync("bash", ["ralph/harden-watchdog.sh", "https://example.com"], {
        cwd: tmpDir,
        env: { ...process.env, HARDEN_MAX_RETRIES: "1" },
        encoding: "utf8",
        stdio: "pipe",
      });
    } catch (error) {
      const err = error as { status?: number; stdout?: Buffer; stderr?: Buffer };
      exitCode = err.status ?? 1;
      output = `${err.stdout?.toString() ?? ""}${err.stderr?.toString() ?? ""}`;
    }

    expect(exitCode).toBe(1);
    expect(output).toContain("BLOCKER gap-failing: verifier failed (false)");
    expect(output).toContain("Phase 6: BLOCKED after 1 attempts. Remaining gaps: gap-failing");
    expect(fs.existsSync(path.join(tmpDir, "ralph/harden-learnings.md"))).toBe(false);
  });
});
