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

## 5.1.5 Execute reviewer verifications

Read `${SESSION_DIR}/reviews/review-final.result` (Phase 4 output). For each issue with `requires_verification: true` (see `phase-4-review.md` Section 4.0 schema), extract `verification.runner` and `verification.target`, validate them against a hardcoded runner-template map plus the documented target rules, then execute the rendered argv via `subprocess.run(argv, shell=False)` from the current working directory. Rocky invokes Phase 5 from the repo root, so `cwd=os.getcwd()` is the repo root at runtime.

This replaces the old Option F wrapper from `6ad3b9d` and closes the round-3 escape vectors by construction. The reviewer no longer supplies a shell command or arbitrary flags; Phase 5 chooses the executable and fixed subcommands from a closed enum, then appends at most one validated target token.

**Safety model:**
1. `runner` must match a key in `VERIFICATION_RUNNERS` exactly. Unknown or missing runners are rejected and counted as `verifications_missing`.
2. `target` validation is runner-aware. Empty is valid. Non-empty targets must have no leading dash, no leading slash, no whitespace, no shell metacharacters or null byte, no `..` path component, and length `<= 512`. `go-test` additionally requires a non-empty target to start with `./`.
3. The final argv is constructed as `VERIFICATION_RUNNERS[runner] + ([target] if target else [])`. No string concatenation and no shell command rendering.
4. Execution is `subprocess.run(argv, shell=False, cwd=os.getcwd(), ...)` with the ambient environment inherited. Rocky runs this phase from the repo root, so the current working directory is the repo root in practice. Do not pass `env=`.

**Residual limitation (narrow, explicit):** This is the narrower post-Option-F model documented in `phase-4-review.md` Section 4.0. It closes the flag-injection category by construction, but it does not make test code itself untrusted. Reviewers can still choose which in-repo tests, packages, or node IDs to run, and those targets execute under the project's normal trust boundary. The architectural history is documented in the rocky project memory.

```bash
VERIFY_LOG="${SESSION_DIR}/verify-cmd-results.txt"
: > "${VERIFY_LOG}"

read -r N_RUN N_FAILED N_MISSING < <(
python3 - "${SESSION_DIR}/reviews/review-final.result" "${VERIFY_LOG}" << 'PYEOF'
import os
import re
import subprocess
import sys
from pathlib import Path

VERIFICATION_RUNNERS = {
    'pytest': ['pytest'],
    'rspec': ['rspec'],
    'go-test': ['go', 'test'],
    'cargo-test': ['cargo', 'test'],
    'npm-test': ['npm', 'test'],
    'yarn-test': ['yarn', 'test'],
    'pnpm-test': ['pnpm', 'test'],
    'bundle-exec-rspec': ['bundle', 'exec', 'rspec'],
    'script-test': ['./scripts/test'],
    'script-verify': ['./scripts/verify'],
}

_FORBIDDEN = re.compile(r"[\s;&|<>`$()\\\x00]")
_MAX_TARGET_LEN = 512


def strip_quotes(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def validate_target(target, runner):
    if target == '':
        return True, 'ok'
    if len(target) > _MAX_TARGET_LEN:
        return False, 'too-long'
    if target.startswith('-'):
        return False, 'leading-dash'
    if target.startswith('/'):
        return False, 'leading-slash'
    if _FORBIDDEN.search(target):
        return False, 'forbidden-char'
    if any(part == '..' for part in target.split('/')):
        return False, 'parent-component'
    if runner == 'go-test' and not target.startswith('./'):
        return False, 'go-test-target-must-start-dot-slash'
    return True, 'ok'


def parse_verifications(path):
    review_path = Path(path)
    if not review_path.exists():
        return

    in_yaml = False
    in_verification = False
    req = False
    runner = None
    target = None

    with review_path.open('r', encoding='utf-8') as handle:
        for raw_line in handle:
            line = raw_line.rstrip('\n')

            if line.startswith('```yaml'):
                in_yaml = True
                in_verification = False
                req = False
                runner = None
                target = None
                continue

            if in_yaml and line.startswith('```'):
                yield req, runner, target
                in_yaml = False
                in_verification = False
                req = False
                runner = None
                target = None
                continue

            if not in_yaml:
                continue

            if line.startswith('requires_verification:'):
                value = line.split(':', 1)[1].strip().lower()
                req = value == 'true'
                in_verification = False
                continue

            if line.startswith('verification:'):
                in_verification = True
                continue

            if in_verification:
                if line.startswith((' ', '\t')):
                    stripped = line.lstrip(' \t')
                    if stripped.startswith('runner:'):
                        runner = strip_quotes(stripped.split(':', 1)[1])
                        continue
                    if stripped.startswith('target:'):
                        target = strip_quotes(stripped.split(':', 1)[1])
                        continue
                elif line:
                    in_verification = False


def log_line(handle, text=''):
    handle.write(text + '\n')


def main(review_path_arg, log_path_arg):
    review_path = review_path_arg
    log_path = Path(log_path_arg)
    log_path.write_text('', encoding='utf-8')

    n_run = 0
    n_failed = 0
    n_missing = 0

    with log_path.open('a', encoding='utf-8') as log_handle:
        for req, runner, target in parse_verifications(review_path):
            if not req:
                continue
            if not runner or runner not in VERIFICATION_RUNNERS:
                n_missing += 1
                log_line(log_handle, f'=== REJECTED runner-invalid runner={runner!r} ===')
                continue
            if target is None:
                target = ''
            valid, reason = validate_target(target, runner)
            if not valid:
                n_missing += 1
                log_line(log_handle, f'=== REJECTED target-invalid reason={reason} runner={runner} target={target!r} ===')
                continue

            argv = list(VERIFICATION_RUNNERS[runner])
            if target:
                argv.append(target)

            n_run += 1
            log_line(log_handle, f'=== RUN runner={runner} target={target!r} ===')
            log_line(log_handle, f'argv={argv!r}')
            try:
                completed = subprocess.run(
                    argv,
                    cwd=os.getcwd(),
                    capture_output=True,
                    text=True,
                    timeout=600,
                    shell=False,
                )
                exit_code = completed.returncode
                stdout = completed.stdout
                stderr = completed.stderr
            except FileNotFoundError as exc:
                # Runner binary not on PATH: verification could not be attempted,
                # so reclassify from failed to missing. The n_run increment at
                # line 178 is left in place (counts as "attempted") because the
                # state-classification logic at Section 5.3 routes on
                # verifications_missing > 0 regardless of n_run.
                exit_code = 127
                stdout = ''
                stderr = str(exc)
                n_missing += 1
            except subprocess.TimeoutExpired as exc:
                exit_code = -1
                stdout = exc.stdout or ''
                stderr = exc.stderr or ''
                if str(exc):
                    stderr = f'{stderr}\n{exc}'.strip()
                n_failed += 1
            except Exception as exc:
                exit_code = -1
                stdout = ''
                stderr = str(exc)
                n_failed += 1
            else:
                if exit_code != 0:
                    n_failed += 1

            log_line(log_handle, 'stdout:')
            log_line(log_handle, stdout)
            log_line(log_handle, 'stderr:')
            log_line(log_handle, stderr)
            log_line(log_handle, f'exit={exit_code}')
            log_line(log_handle)

    return n_run, n_failed, n_missing


if len(sys.argv) >= 3:
    n_run, n_failed, n_missing = main(sys.argv[1], sys.argv[2])
    print(f'{n_run} {n_failed} {n_missing}')
PYEOF
)

swarm_update_ledger_field "${SESSION_DIR}" "verifications_run" "${N_RUN}"
swarm_update_ledger_field "${SESSION_DIR}" "verifications_failed" "${N_FAILED}"
swarm_update_ledger_field "${SESSION_DIR}" "verifications_missing" "${N_MISSING}"
```

**Rejection handling:** Missing or invalid `verification` data is counted as `verifications_missing`. That includes unknown runners, omitted runner blocks, and invalid targets. Empty target is valid and means whole-suite or runner-default behavior. `verifications_missing` feeds `human_needed` at 5.3, where the user sees the rejection reason and decides whether to correct the review output or inspect manually.

**Feeds into 5.3 classification:**
- All verifications exit 0 AND none missing → no additional gap evidence from this step.
- Any `verifications_failed > 0` → contributes to `gaps_found`. The failing verification outputs in `verify-cmd-results.txt` become gap evidence for 5.4.
- Any `verifications_missing > 0` → contributes to `human_needed` (reviewer tagged an issue as requiring verification but did not provide actionable structured verification data; the human must inspect).

If Phase 4 produced no review output file (missing `reviews/review-final.result`) → skip 5.1.5 silently and proceed to 5.2. Missing review is its own failure mode handled elsewhere.

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
| `passed` | All deterministic tests green + all tasks DONE + plan fully covered + all verifications exit 0 + no missing verifications | Auto-proceed to Phase 6 |
| `gaps_found` | Deterministic test failures OR any task FAILED OR plan coverage incomplete OR any `verifications_failed > 0` | Gap closure cycle (5.4) |
| `human_needed` | All automated checks pass but items need manual verification, OR infrastructure/flaky failures detected, OR any `verifications_missing > 0` (reviewer required verification but provided no actionable `verification` block) | Present targeted checklist to user, continue on approval |

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
