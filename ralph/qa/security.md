---

## SUB-PHASE C: SECURITY

Run targeted security checks relevant to this feature. Focus on the most impactful checks; do not run exhaustive scans.

### Step C1: Auth bypass
Try accessing every API endpoint for this feature without authentication:
```bash
curl -s -X GET http://localhost:3015/api/<endpoint> | jq .
# Must return 401, never 200 with data
```
Try accessing protected UI pages without a session:
```bash
curl -s -L http://localhost:3015/<protected-page> | grep -i "login\|unauthorized"
```

### Step C2: Input sanitization
Test inputs that could cause injection or unexpected behavior:
```bash
# SQL injection probe
curl -s -X POST http://localhost:3015/api/<endpoint> \
  -H "Authorization: Bearer $DASHBOARD_KEY" \
  -H "Content-Type: application/json" \
  -d '{"field": "'"'"' OR 1=1 --"}' | jq .

# XSS probe (check if reflected unsanitized in response)
curl -s -X POST http://localhost:3015/api/<endpoint> \
  -H "Authorization: Bearer $DASHBOARD_KEY" \
  -H "Content-Type: application/json" \
  -d '{"field": "<script>alert(1)</script>"}' | jq .
```
Verify: no SQL errors leaked, XSS payloads not reflected as raw HTML.

### Step C3: CORS check
```bash
curl -s -I -X OPTIONS http://localhost:3015/api/<endpoint> \
  -H "Origin: https://evil.com" \
  -H "Access-Control-Request-Method: POST" | grep -i "access-control"
```
Verify: `Access-Control-Allow-Origin` does NOT echo back `https://evil.com` or `*` for credentialed routes.

### Step C4: Sensitive data exposure
Check that API responses never leak:
- Passwords or password hashes
- Full database IDs where short/opaque IDs should be used
- Internal server paths or stack traces
- Environment variable values

### Step C5: Record security results
Note any bypass, injection success, CORS misconfiguration, or data leak. Fix critical/major security findings before moving on.
