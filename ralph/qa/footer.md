---

## Record & Fix

After all included sub-phases are complete, record findings in `qa-report.json` — **append a NEW entry, never overwrite previous ones**.

For any sub-phase NOT included in this prompt, set its status to `"skip"` with notes `"not applicable for this feature category"`.

```json
{
  "feature_id": "feature-001",
  "attempt": 1,
  "status": "pass|fail|partial",
  "sub_phases": {
    "functional": {
      "status": "pass|fail|skip",
      "notes": "brief summary"
    },
    "api_contract": {
      "status": "pass|fail|skip",
      "endpoints_tested": ["GET /api/foo", "POST /api/foo"],
      "notes": "brief summary"
    },
    "security": {
      "status": "pass|fail|skip",
      "checks": ["auth_bypass", "input_sanitization", "cors", "data_exposure"],
      "notes": "brief summary"
    },
    "accessibility": {
      "status": "pass|fail|skip",
      "violations": [],
      "notes": "brief summary"
    }
  },
  "tested_steps": ["step 1 result"],
  "bugs_found": [{ "severity": "critical|major|minor|cosmetic", "phase": "functional|api_contract|security|accessibility", "description": "...", "expected": "...", "actual": "...", "reproduction": "..." }],
  "fix_description": "brief description of what fix was attempted (or 'no fix needed' if passed)"
}
```
If a `== QA HISTORY ==` section is provided in your prompt, read all previous attempts before deciding your fix strategy — do not repeat an approach that already failed.

After recording, fix ALL bugs found across all sub-phases for this feature, then run `make check && make test` once. Commit together: `git commit -m "QA fix: <feature> — fixed N bugs: <brief list>"`

Update `prd.json` for this feature:
- Set `qa_pass: true` if all critical bugs are fixed and feature works end-to-end.
- Set `qa_pass: false` if critical bugs remain unfixed (so the QA loop retries this feature).
- Do NOT touch `build_pass` — that is owned by the build agent.

`git add -A`, detailed commit message, `git push`.

## Rules
- **HARD STOP: Test exactly ONE feature per invocation.** Commit, push, output promise, stop.
- Run all included sub-phases for this feature. Skip only sub-phases not provided in this prompt.
- Be skeptical. Assume things are broken until proven otherwise.
- Fix ALL critical/major bugs for the feature, then test once before committing.
- **NEVER weaken or delete tests to make them pass.** Fix the code, not the test.
- Always update `qa_pass` in `prd.json` before outputting the promise.
- Output `<promise>NEXT</promise>` after committing if more features remain.
- Output `<promise>QA_COMPLETE</promise>` only if ALL features are QA tested and all `qa_pass: true`.

---

## Final Checklist (verify before outputting your promise)

Stop and verify each item. Only the sub-phases included in this prompt need verification — the rest should be marked `skip` in your qa-report entry:

- [ ] **Sub-Phase A (FUNCTIONAL)** — ran unit tests, E2E, manual Ever CLI verification, recorded `status`
- [ ] **All other included sub-phases** — completed per their instructions and recorded in qa-report entry
- [ ] **Excluded sub-phases** — marked as `skip` with reason in qa-report entry
- [ ] **qa-report.json** — appended a NEW entry (did not overwrite previous ones)
- [ ] **prd.json** — updated `qa_pass` for this feature (true only if no critical bugs remain)
- [ ] **`make check && make test`** — ran once, passed
- [ ] **Committed and pushed** with a descriptive message

If ANY checkbox is unticked, go back and do that step before outputting the promise.
