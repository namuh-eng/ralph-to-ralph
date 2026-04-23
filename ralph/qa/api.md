---

## SUB-PHASE B: API CONTRACT

Test every API endpoint relevant to this feature for correct shapes, status codes, and error formats.

### Step B1: Discover Endpoints
List the API routes for this feature. The exact discovery command depends on your stack — check `$STACK_HINTS` in the prompt header or `BUILD_GUIDE.md` for the right incantation. For Next.js App Router, it's `find src/app/api -name "route.ts" | sort`; for Go, grep for `http.HandleFunc`/router mounts; for Python, inspect your framework's router config.
Identify all endpoints touched by the feature under test.

### Step B2: Happy-path contract checks
For each endpoint, send a valid request with curl and verify:
- HTTP status code matches expectation (200, 201, etc.)
- Response body shape matches the documented/expected schema (required fields present, correct types)
- Content-Type is `application/json`

Example:
```bash
curl -s -X GET http://localhost:3015/api/<endpoint> \
  -H "Authorization: Bearer $DASHBOARD_KEY" \
  -H "Content-Type: application/json" | jq .
```

### Step B3: Error format checks
Verify consistent error responses:
- Missing required fields → 400 with `{ error: string }` or `{ errors: [...] }`
- Invalid auth → 401
- Not found → 404
- Server error → 500 (never leaks stack traces)

```bash
# Missing auth
curl -s -X GET http://localhost:3015/api/<endpoint> | jq .
# Expected: 401 { "error": "Unauthorized" }

# Bad input
curl -s -X POST http://localhost:3015/api/<endpoint> \
  -H "Authorization: Bearer $DASHBOARD_KEY" \
  -H "Content-Type: application/json" \
  -d '{}' | jq .
# Expected: 400 with error details
```

### Step B4: Record API contract results
Note any endpoint that returns wrong status codes, malformed bodies, or inconsistent error shapes. These are API contract bugs — fix them before moving on.
