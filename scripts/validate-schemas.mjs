#!/usr/bin/env node
/**
 * validate-schemas.mjs
 * Validates ralph-to-ralph state files against their JSON schemas.
 * Run via: node scripts/validate-schemas.mjs
 * Or:      make validate
 */

import { readFileSync, existsSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");

// ── Minimal JSON Schema draft-07 validator ──────────────────────────────────
// Supports: type, required, enum, properties, additionalProperties,
//           items, minimum, minLength, pattern, format (uri/email — syntax only)

function validateSchema(data, schema, path = "$") {
  const errors = [];

  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    const jsType = data === null ? "null" : Array.isArray(data) ? "array" : typeof data;
    const typeMap = { integer: "number" };
    const matches = types.some((t) => {
      if (t === "integer") return Number.isInteger(data);
      return jsType === (typeMap[t] ?? t);
    });
    if (!matches) {
      errors.push(`${path}: expected type ${types.join("|")}, got ${jsType}`);
      return errors; // can't validate further if wrong type
    }
  }

  if (schema.enum !== undefined) {
    if (!schema.enum.includes(data)) {
      errors.push(`${path}: value ${JSON.stringify(data)} not in enum [${schema.enum.map((v) => JSON.stringify(v)).join(", ")}]`);
    }
  }

  if (schema.minLength !== undefined && typeof data === "string") {
    if (data.length < schema.minLength) {
      errors.push(`${path}: string length ${data.length} < minLength ${schema.minLength}`);
    }
  }

  if (schema.minimum !== undefined && typeof data === "number") {
    if (data < schema.minimum) {
      errors.push(`${path}: value ${data} < minimum ${schema.minimum}`);
    }
  }

  if (schema.pattern !== undefined && typeof data === "string") {
    const re = new RegExp(schema.pattern);
    if (!re.test(data)) {
      errors.push(`${path}: string does not match pattern ${schema.pattern}`);
    }
  }

  if (schema.format && typeof data === "string") {
    if (schema.format === "uri") {
      try { new URL(data); } catch {
        errors.push(`${path}: invalid URI format: ${data}`);
      }
    }
    if (schema.format === "email") {
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(data)) {
        errors.push(`${path}: invalid email format: ${data}`);
      }
    }
    if (schema.format === "date-time" && data !== null) {
      if (Number.isNaN(Date.parse(data))) {
        errors.push(`${path}: invalid date-time format: ${data}`);
      }
    }
  }

  if (schema.required && typeof data === "object" && data !== null && !Array.isArray(data)) {
    for (const key of schema.required) {
      if (!(key in data)) {
        errors.push(`${path}: missing required property "${key}"`);
      }
    }
  }

  if (schema.properties && typeof data === "object" && data !== null && !Array.isArray(data)) {
    for (const [key, subSchema] of Object.entries(schema.properties)) {
      if (key in data) {
        errors.push(...validateSchema(data[key], subSchema, `${path}.${key}`));
      }
    }
  }

  if (schema.items && Array.isArray(data)) {
    for (let i = 0; i < data.length; i++) {
      errors.push(...validateSchema(data[i], schema.items, `${path}[${i}]`));
    }
  }

  return errors;
}

// ── Load schema helper ──────────────────────────────────────────────────────

function loadSchema(relPath) {
  const full = resolve(ROOT, relPath);
  return JSON.parse(readFileSync(full, "utf8"));
}

function loadData(relPath) {
  const full = resolve(ROOT, relPath);
  if (!existsSync(full)) return null;
  return JSON.parse(readFileSync(full, "utf8"));
}

// ── Validation targets ──────────────────────────────────────────────────────

const targets = [
  {
    label: "ralph-config.json",
    dataPath: "ralph-config.json",
    schemaPath: "schemas/ralph-config.schema.json",
    required: false, // may not exist yet (pre-onboard)
  },
  {
    label: "prd.json (array of items)",
    dataPath: "prd.json",
    schemaPath: "schemas/prd-item.schema.json",
    isArray: true,
    required: false,
  },
  {
    label: "qa-report.json (array of entries)",
    dataPath: "qa-report.json",
    schemaPath: "schemas/qa-report-entry.schema.json",
    isArray: true,
    required: false,
  },
  {
    label: "ralph/ralph-state.json (if present)",
    dataPath: "ralph/ralph-state.json",
    schemaPath: "ralph/ralph-state.schema.json",
    required: false,
  },
];

// ── Run validations ─────────────────────────────────────────────────────────

let totalErrors = 0;
let totalChecked = 0;
let totalSkipped = 0;

const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const RESET = "\x1b[0m";

console.log("\n=== ralph-to-ralph schema validation ===\n");

for (const target of targets) {
  const data = loadData(target.dataPath);

  if (data === null) {
    if (target.required) {
      console.log(`${RED}MISSING${RESET}  ${target.label} — file not found (required)`);
      totalErrors++;
    } else {
      console.log(`${YELLOW}SKIP${RESET}     ${target.label} — file not found (optional)`);
      totalSkipped++;
    }
    continue;
  }

  const schema = loadSchema(target.schemaPath);
  let errors = [];

  if (target.isArray) {
    if (!Array.isArray(data)) {
      errors.push("$: expected array at root");
    } else {
      for (let i = 0; i < data.length; i++) {
        errors.push(...validateSchema(data[i], schema, `$[${i}]`));
      }
    }
  } else {
    errors = validateSchema(data, schema, "$");
  }

  totalChecked++;

  if (errors.length === 0) {
    const count = target.isArray ? ` (${data.length} items)` : "";
    console.log(`${GREEN}PASS${RESET}     ${target.label}${count}`);
  } else {
    console.log(`${RED}FAIL${RESET}     ${target.label} — ${errors.length} error(s):`);
    for (const err of errors) {
      console.log(`           ${RED}✗${RESET} ${err}`);
    }
    totalErrors += errors.length;
  }
}

console.log(`\n─────────────────────────────────────────`);
console.log(`Checked: ${totalChecked}  Skipped: ${totalSkipped}  Errors: ${totalErrors}`);

if (totalErrors > 0) {
  console.log(`\n${RED}Validation failed.${RESET} Fix the errors above.\n`);
  process.exit(1);
} else {
  console.log(`\n${GREEN}All validations passed.${RESET}\n`);
  process.exit(0);
}
