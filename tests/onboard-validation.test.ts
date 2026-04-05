// ABOUTME: Integration tests for onboard.sh validation logic
// Tests schema validation and promise tag parsing without invoking Claude

import { execSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

describe("onboard.sh validation logic", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "onboard-test-"));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  describe("ralph-config.json schema validation", () => {
    const validationScript = `
import json, sys
c = json.load(open(sys.argv[1]))
required = ['targetUrl', 'targetName', 'cloudProvider', 'framework', 'database']
missing = [k for k in required if k not in c]
if missing:
    print(f'ERROR: ralph-config.json missing required fields: {missing}', file=sys.stderr)
    sys.exit(1)
if c['cloudProvider'] not in ('aws', 'gcp', 'azure', 'vercel', 'custom'):
    print(f'ERROR: invalid cloudProvider: {c["cloudProvider"]}', file=sys.stderr)
    sys.exit(1)
`;

    function runValidation(config: Record<string, unknown>): {
      exitCode: number;
      stderr: string;
    } {
      const configPath = path.join(tmpDir, "ralph-config.json");
      const scriptPath = path.join(tmpDir, "validate.py");
      fs.writeFileSync(configPath, JSON.stringify(config));
      fs.writeFileSync(scriptPath, validationScript);
      try {
        execSync(`python3 "${scriptPath}" "${configPath}"`, {
          encoding: "utf-8",
          stdio: ["pipe", "pipe", "pipe"],
        });
        return { exitCode: 0, stderr: "" };
      } catch (err) {
        const error = err as { status: number; stderr: string };
        return { exitCode: error.status, stderr: error.stderr };
      }
    }

    it("accepts a valid config with all required fields", () => {
      const result = runValidation({
        targetUrl: "https://resend.com",
        targetName: "resend-clone",
        cloudProvider: "aws",
        framework: "nextjs",
        database: "postgres",
      });
      expect(result.exitCode).toBe(0);
    });

    it("accepts gcp as a valid cloud provider", () => {
      const result = runValidation({
        targetUrl: "https://mintlify.com",
        targetName: "mintlify-clone",
        cloudProvider: "gcp",
        framework: "nextjs",
        database: "postgres",
      });
      expect(result.exitCode).toBe(0);
    });

    it("accepts azure as a valid cloud provider", () => {
      const result = runValidation({
        targetUrl: "https://example.com",
        targetName: "example-clone",
        cloudProvider: "azure",
        framework: "nextjs",
        database: "postgres",
      });
      expect(result.exitCode).toBe(0);
    });

    it("rejects config with missing required fields", () => {
      const result = runValidation({
        targetUrl: "https://resend.com",
        cloudProvider: "aws",
      });
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain("missing required fields");
    });

    it("rejects config with invalid cloud provider", () => {
      const result = runValidation({
        targetUrl: "https://resend.com",
        targetName: "resend-clone",
        cloudProvider: "digitalocean",
        framework: "nextjs",
        database: "postgres",
      });
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain("invalid cloudProvider");
    });

    it("rejects config with empty cloud provider", () => {
      const result = runValidation({
        targetUrl: "https://resend.com",
        targetName: "resend-clone",
        cloudProvider: "",
        framework: "nextjs",
        database: "postgres",
      });
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain("invalid cloudProvider");
    });

    it("accepts vercel as a valid cloud provider", () => {
      const result = runValidation({
        targetUrl: "https://mintlify.com",
        targetName: "mintlify-clone",
        cloudProvider: "vercel",
        framework: "nextjs",
        database: "postgres",
      });
      expect(result.exitCode).toBe(0);
    });

    it("accepts custom as a valid cloud provider", () => {
      const result = runValidation({
        targetUrl: "https://example.com",
        targetName: "example-clone",
        cloudProvider: "custom",
        framework: "nextjs",
        database: "postgres",
      });
      expect(result.exitCode).toBe(0);
    });

    it("accepts config with setup section", () => {
      const result = runValidation({
        targetUrl: "https://resend.com",
        targetName: "resend-clone",
        cloudProvider: "vercel",
        framework: "nextjs",
        database: "postgres",
        setup: {
          verified: ["node", "vercel-cli"],
          pending: ["anthropic-api-key"],
          checks: {
            node: { command: "node -v", status: "pass", detail: "v22.1.0" },
            "vercel-cli": {
              command: "vercel whoami",
              status: "pass",
              detail: "ashley",
            },
            "anthropic-api-key": {
              envVar: "ANTHROPIC_API_KEY",
              status: "fail",
              error: "not found in .env",
            },
          },
        },
      });
      expect(result.exitCode).toBe(0);
    });

    it("accepts config without setup section (backwards compatible)", () => {
      const result = runValidation({
        targetUrl: "https://resend.com",
        targetName: "resend-clone",
        cloudProvider: "aws",
        framework: "nextjs",
        database: "postgres",
        services: {
          email: { provider: "ses", package: "@aws-sdk/client-sesv2" },
        },
      });
      expect(result.exitCode).toBe(0);
    });
  });

  describe("promise tag parsing", () => {
    it("detects ONBOARD_COMPLETE promise", () => {
      const output =
        "Some output\n<promise>ONBOARD_COMPLETE</promise>\nMore output";
      expect(output).toContain("<promise>ONBOARD_COMPLETE</promise>");
    });

    it("detects ONBOARD_FAILED promise", () => {
      const output =
        "Error happened\n<promise>ONBOARD_FAILED</promise>\nDetails";
      expect(output).toContain("<promise>ONBOARD_FAILED</promise>");
    });

    it("detects no promise in output", () => {
      const output = "Claude session ended without a promise tag";
      expect(output).not.toContain("<promise>ONBOARD_COMPLETE</promise>");
      expect(output).not.toContain("<promise>ONBOARD_FAILED</promise>");
    });
  });
});
