// ABOUTME: Unit tests for DB_SSL env var behavior in drizzle.config.ts
// Verifies sslmode=no-verify is appended when DB_SSL=true

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Helper to extract dbCredentials.url from the drizzle config
// The Config type is a union — dbCredentials only exists on certain branches
function getDbUrl(config: unknown): string {
  return (config as { dbCredentials: { url: string } }).dbCredentials.url;
}

describe("drizzle.config.ts SSL configuration", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.unstubAllEnvs();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("appends sslmode=no-verify when DB_SSL=true", async () => {
    vi.stubEnv("DB_SSL", "true");
    vi.stubEnv("DATABASE_URL", "postgresql://localhost:5432/test");

    const mod = await import("../drizzle.config");

    expect(getDbUrl(mod.default)).toBe(
      "postgresql://localhost:5432/test?sslmode=no-verify",
    );
  });

  it("does not append sslmode when DB_SSL is unset", async () => {
    vi.stubEnv("DATABASE_URL", "postgresql://localhost:5432/test");
    // biome-ignore lint/performance/noDelete: process.env needs delete — assignment coerces to string "undefined"
    delete process.env.DB_SSL;

    const mod = await import("../drizzle.config");

    expect(getDbUrl(mod.default)).toBe("postgresql://localhost:5432/test");
  });

  it("does not append sslmode when DB_SSL=false", async () => {
    vi.stubEnv("DB_SSL", "false");
    vi.stubEnv("DATABASE_URL", "postgresql://localhost:5432/test");

    const mod = await import("../drizzle.config");

    expect(getDbUrl(mod.default)).toBe("postgresql://localhost:5432/test");
  });

  it("does not double-append sslmode if already present", async () => {
    vi.stubEnv("DB_SSL", "true");
    vi.stubEnv(
      "DATABASE_URL",
      "postgresql://localhost:5432/test?sslmode=require",
    );

    const mod = await import("../drizzle.config");

    expect(getDbUrl(mod.default)).toBe(
      "postgresql://localhost:5432/test?sslmode=require",
    );
  });
});
