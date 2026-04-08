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

## 5.1.5 Execute reviewer verify_cmds

Read `${SESSION_DIR}/reviews/review-final.result` (Phase 4 output). For each issue with `requires_verification: true` (see `phase-4-review.md` Section 4.0 schema), extract the `verify_cmd` and execute it under a strict safe-mode wrapper from the repo root.

**Safety rationale:** Reviewer output is machine-generated. A hallucinated or prompt-injected reviewer could emit destructive shell. Phase 5 enforces a three-layer gate before executing any command: (1) first-token allowlist, (2) subcommand constraint for tools that have one, (3) metacharacter + runner-specific flag denylist. The allowlist/denylists MUST stay in sync with `phase-4-review.md` Section 4.0's documented safety constraints.

**KNOWN LIMITATION — NOT A SECURITY BOUNDARY.** These filters reduce the surface of reviewer-supplied code execution but do NOT hermetically prevent it. Test runners have extension mechanisms (plugin configs, `conftest.py`, import side-effects from test selectors, runner-specific passthrough options) that this filter does not and cannot catch via a static allowlist. This is a pragmatic close, accepted because rocky is local-only and the bounded threat model is LLM hallucination or prompt-injection through reviewed code on the user's own machine — NOT network-accessible untrusted input. The clean architectural fix is to replace freeform `verify_cmd` strings with structured verification data that Phase 5 renders from a hardcoded template; deferred to a future rocky session. Do NOT rely on this wrapper as a security boundary.

```bash
VERIFY_LOG="${SESSION_DIR}/verify-cmd-results.txt"
: > "${VERIFY_LOG}"

N_RUN=0
N_FAILED=0
N_MISSING=0

# Safe-mode checker: returns 0 if cmd is safe to execute, 1 otherwise.
# Writes a short rejection reason to stdout on failure.
# Keep in sync with phase-4-review.md Section 4.0 safety constraints.
#
# Rationale: first-token allowlisting alone is insufficient because interpreters
# like `python -c "..."` can execute arbitrary reviewer-supplied code, AND
# runner-specific flags like `pytest -p` or `go test -exec` load arbitrary
# wrappers even inside allowlisted entrypoints. This checker enforces four
# layers: (1) metacharacter denylist, (2) standalone vs subcommand-
# constrained allowlist, (3) explicit general-interpreter rejection, (4)
# runner-specific flag denylist for known escape hatches. This is a
# reduced-surface pragmatic gate, NOT a sound execution boundary. See the
# "KNOWN LIMITATION" banner above and feedback_verify_cmd_execution_safety.md
# in the user's memory for the architectural context.
swarm_verify_cmd_safe() {
  local cmd="$1"
  [[ -z "${cmd}" ]] && { echo "empty"; return 1; }

  # Layer 1: metacharacter denylist — no shell composition allowed
  case "${cmd}" in
    *';'*|*'&&'*|*'||'*|*'|'*|*'>'*|*'<'*|*'`'*|*'$('*|*'$(('*|*$'\n'*)
      echo "metachar-rejected"; return 1 ;;
  esac

  # Tokenize first two tokens (used by both flag denylist and allowlist below)
  local first="${cmd%% *}"
  local rest="${cmd#* }"
  local second=""
  [[ "${rest}" != "${cmd}" ]] && second="${rest%% *}"

  # Layer 4: runner-context-aware flag denylist.
  # Uses per-token inspection to catch BOTH space-delimited (`-r value`) and
  # attached-value (`-rvalue`) forms of dangerous flags. Context-aware so
  # legitimate flags in one runner are not false-positived against another
  # (e.g. pytest's `-r chars` for summary reporting is safe; rspec's `-r X`
  # requires a Ruby file and is dangerous). Safe because the metacharacter
  # denylist above already rejects newlines/pipes/etc., so word-splitting
  # the cmd into tokens is well-defined.
  local _tok
  for _tok in ${cmd}; do
    # pytest plugin/module loading — applies only when runner is pytest
    if [[ "${first}" == "pytest" ]]; then
      case "${_tok}" in
        -p|--plugin|--pyargs|--plugin=*|--pyargs=*|-p[!-]*)
          echo "flag-rejected:pytest-plugin:${_tok}"; return 1 ;;
      esac
    fi
    # rspec require flags — applies to standalone rspec and bundle exec rspec
    if [[ "${first}" == "rspec" || ( "${first}" == "bundle" && "${second}" == "exec" ) ]]; then
      case "${_tok}" in
        -r|--require|--require=*|-r[!-]*)
          echo "flag-rejected:ruby-require:${_tok}"; return 1 ;;
      esac
    fi
    # go test wrapper flags — applies only to "go test"
    if [[ "${first}" == "go" && "${second}" == "test" ]]; then
      case "${_tok}" in
        -exec|-exec=*|-toolexec|-toolexec=*)
          echo "flag-rejected:go-wrapper:${_tok}"; return 1 ;;
      esac
    fi
  done

  # Standalone allowed test runners — any args permitted (already passed denylist)
  case "${first}" in
    pytest|rspec|./scripts/test|./scripts/verify) return 0 ;;
  esac

  # Subcommand-constrained tools — require specific second token
  case "${first} ${second}" in
    "go test"|"cargo test"|"npm test"|"yarn test"|"pnpm test") return 0 ;;
    "bundle exec")
      # bundle exec requires a specific third token (rspec only for now)
      local rest2="${rest#* }"
      local third=""
      [[ "${rest2}" != "${rest}" ]] && third="${rest2%% *}"
      if [[ "${third}" == "rspec" ]]; then
        return 0
      fi
      echo "bundle-exec-subcommand:${third:-<missing>}"; return 1 ;;
  esac

  # Explicit rejection list for clarity in logs
  case "${first}" in
    python|python3|make|sh|bash|zsh|perl|ruby|node)
      echo "general-interpreter-rejected:${first}"; return 1 ;;
  esac

  echo "not-allowlisted:${first}${second:+ }${second}"
  return 1
}

# Extract verify_cmd lines from the review output. Matches `verify_cmd: "..."`
# scoped to issues with `requires_verification: true` (same yaml block).
# Uses awk to pair the two fields within each ```yaml ... ``` block.
while IFS= read -r cmd; do
  if [[ -z "${cmd}" ]]; then
    N_MISSING=$((N_MISSING + 1))
    echo "=== MISSING verify_cmd ===" >> "${VERIFY_LOG}"
    continue
  fi
  # Safe-mode gate — reject commands that fail allowlist or metacharacter checks
  reject_reason=$(swarm_verify_cmd_safe "${cmd}")
  if [[ $? -ne 0 ]]; then
    N_MISSING=$((N_MISSING + 1))
    echo "=== REJECTED (${reject_reason}): ${cmd} ===" >> "${VERIFY_LOG}"
    continue
  fi
  N_RUN=$((N_RUN + 1))
  echo "=== ${cmd} ===" >> "${VERIFY_LOG}"
  # Use `env -i` + minimal PATH to reduce environment-based attack surface.
  # Still uses bash -c because test runners often rely on shell features,
  # but the input has been gated by the allowlist + denylist above.
  env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="${HOME}" bash -c "${cmd}" >> "${VERIFY_LOG}" 2>&1
  rc=$?
  echo "exit=${rc}" >> "${VERIFY_LOG}"
  [[ ${rc} -ne 0 ]] && N_FAILED=$((N_FAILED + 1))
done < <(awk '
  /^```yaml/ { in_yaml=1; req=""; cmd=""; next }
  /^```/ && in_yaml { in_yaml=0; if (req=="true") print cmd; next }
  in_yaml && /^requires_verification:/ { req=$2 }
  in_yaml && /^verify_cmd:/ {
    sub(/^verify_cmd:[[:space:]]*"?/, "")
    sub(/"?[[:space:]]*$/, "")
    cmd=$0
  }
' "${SESSION_DIR}/reviews/review-final.result" 2>/dev/null || true)

swarm_update_ledger_field "${SESSION_DIR}" "verify_cmds_run" "${N_RUN}"
swarm_update_ledger_field "${SESSION_DIR}" "verify_cmds_failed" "${N_FAILED}"
swarm_update_ledger_field "${SESSION_DIR}" "verify_cmds_missing" "${N_MISSING}"
```

**Rejection handling:** Commands rejected by safe-mode (empty, metacharacter-rejected, or not-allowlisted) are counted as `verify_cmds_missing` — treated identically to a reviewer who forgot to provide `verify_cmd`. They feed `human_needed` at 5.3, where the user sees the rejected command and decides whether to authorize it manually or rewrite the issue.

**Feeds into 5.3 classification:**
- All verify_cmds exit 0 AND none missing → no additional gap evidence from this step.
- Any `verify_cmds_failed > 0` → contributes to `gaps_found`. The failing `verify_cmd` outputs in `verify-cmd-results.txt` become gap evidence for 5.4.
- Any `verify_cmds_missing > 0` → contributes to `human_needed` (reviewer tagged an issue as requiring verification but did not provide an actionable check; the human must inspect).

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
| `passed` | All deterministic tests green + all tasks DONE + plan fully covered + all verify_cmds exit 0 + no missing verify_cmds | Auto-proceed to Phase 6 |
| `gaps_found` | Deterministic test failures OR any task FAILED OR plan coverage incomplete OR any `verify_cmds_failed > 0` | Gap closure cycle (5.4) |
| `human_needed` | All automated checks pass but items need manual verification, OR infrastructure/flaky failures detected, OR any `verify_cmds_missing > 0` (reviewer required verification but provided no verify_cmd) | Present targeted checklist to user, continue on approval |

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
