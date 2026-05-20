import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");

const read = (relativePath: string) =>
	fs.readFileSync(path.join(repoRoot, relativePath), "utf8");

describe("lazy context manifests", () => {
	it("keeps inspect and build loop context files as manifest paths instead of eager @file references", () => {
		const inspect = read("ralph/inspect-ralph.sh");
		const build = read("ralph/build-ralph.sh");

		for (const content of [inspect, build]) {
			expect(content).toContain("== CONTEXT FILES");
		}

		expect(inspect).toContain("@ralph/inspect-prompt.md");
		expect(inspect).not.toContain("@ralph/inspect-spec.md");
		expect(inspect).not.toContain("@prd.json");
		expect(inspect).not.toContain("@inspect-progress.txt");
		expect(inspect).not.toContain("@ralph/pre-setup.md");
		expect(inspect).not.toContain("@ralph-config.json");
		expect(inspect).not.toContain("@ralph/ever-cli-reference.md");

		expect(build).toContain("@ralph/build-prompt.md");
		expect(build).not.toContain("@ralph/pre-setup.md");
		expect(build).not.toContain("@build-spec.md");
		expect(build).not.toContain("@prd.json");
		expect(build).not.toContain("@build-progress.txt");
		expect(build).not.toContain("@CLAUDE.md");
		expect(build).not.toContain("@ralph-config.json");
		expect(build).not.toContain("@qa-report.json");
	});

	it("keeps architecture context files as manifest paths instead of eager @file references", () => {
		const watchdog = read("ralph/ralph-watchdog.sh");

		expect(watchdog).toContain("@ralph/architecture-prompt.md");
		expect(watchdog).toContain("== CONTEXT FILES");
		expect(watchdog).not.toContain("@prd.json");
		expect(watchdog).not.toContain("@target-docs/INDEX.md");
		expect(watchdog).not.toContain("@ralph-config.json");
	});

	it("tells agents which manifest files must be read before acting", () => {
		expect(read("ralph/inspect-prompt.md")).toContain(
			"## Required Reads Before Acting",
		);
		expect(read("ralph/build-prompt.md")).toContain(
			"## Required Reads Before Acting",
		);
		expect(read("ralph/architecture-prompt.md")).toContain(
			"## Required Reads Before Deciding",
		);
	});
});
