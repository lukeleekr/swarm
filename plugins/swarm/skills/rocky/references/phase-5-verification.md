# Phase 5: Verification Routing

> Loaded by `SKILL.md` Phase 5 pointer. Contains the full verification implementation: automated checks, flaky test pre-filter, state classification, gap closure cycle (regression-gated), and the human-needed checklist.

## 5.1 Run automated checks

```bash
# Full test suite with detail
pytest --tb=short 2>&1 | tee "${SESSION_DIR}/verify-pytest.txt"
PYTEST_EXIT=$?

# Git state
git diff --stat > "${SESSION_DIR}/verify-git-diff.txt"
git status --short > "${SESSION_DIR}/verify-git-status.txt"
```

Read all `.result` files. Check: are all tasks DONE? Does the output cover the original plan/spec?

## 5.2 Flaky test pre-filter

If `PYTEST_EXIT != 0` (tests failed):

1. Extract failing test IDs from pytest output
2. Rerun ONLY the failing tests (up to 2 retries):
   ```bash
   pytest --tb=short --lf 2>&1  # --lf = last failed
   ```
3. Classify each failure:
   - **Deterministic** (fails on all retries) → code gap, feeds into `gaps_found`
   - **Flaky** (passes on retry) → exclude from gap analysis, flag in report
   - **Infrastructure** (ImportError, ConnectionRefused, timeout) → route to `human_needed`

## 5.3 Classify verification state

| State | Condition | Action |
|---|---|---|
| `passed` | All deterministic tests green + all tasks DONE + plan fully covered | Auto-proceed to Phase 6 |
| `gaps_found` | Deterministic test failures OR any task FAILED OR plan coverage incomplete | Gap closure cycle (5.4) |
| `human_needed` | All automated checks pass but items need manual verification, OR infrastructure/flaky failures detected | Present targeted checklist to user, continue on approval |

```bash
swarm_update_ledger_field "${SESSION_DIR}" "verification_state" "${STATE}"
swarm_set_progress "Verified: ${STATE}" "0.9"
```

## 5.4 Gap closure cycle (when `gaps_found`)

Max 1 gap-closure round. If `gap_closure_round` already equals 1 → skip closure, escalate to user.

1. **Analyze failures**: read `verify-pytest.txt`, `.result` files, `verify-git-diff.txt`
2. **Snapshot pre-closure test state** (regression-gate the closure):
   ```bash
   pytest --tb=no -q --junitxml="${SESSION_DIR}/test-pre-closure.xml" 2>/dev/null || true
   ```
3. **Create NEW targeted fix tasks** (not retries of originals):
   - Write fix task files to `${SESSION_DIR}/tasks/fix-NNN.md` with same template
   - Include pytest error output and relevant git diff in the assignment
4. **Dispatch fix tasks** to agents (same dispatch mechanism as Phase 3)
5. **Regression-check the closure**:
   ```bash
   pytest --tb=line -q --junitxml="${SESSION_DIR}/test-post-closure.xml" 2>/dev/null || true
   ```
   Compare `test-post-closure.xml` against `test-pre-closure.xml` using `swarm_extract_passing_tests`.
   If any previously-passing test now fails → the closure introduced a regression. Include in escalation.
6. **Update ledger**:
   ```bash
   swarm_update_ledger_field "${SESSION_DIR}" "gap_closure_round" "1"
   ```
7. **Re-run verification** (back to 5.1). If state is still `gaps_found` → escalate to user with full diagnosis.

## 5.5 Human-needed checklist

When state is `human_needed`, present a targeted checklist:

```markdown
## Manual Verification Needed

The following items could not be verified automatically:

- [ ] [Item 1: description of what to check]
- [ ] [Item 2: flaky test that needs investigation]
- [ ] [Item 3: infrastructure issue that needs resolution]

Please verify and confirm to continue.
```

On user approval → set `verification_state: passed`, proceed to Phase 6.
On user rejection → escalate with user's feedback.
