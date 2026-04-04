---
description: "Manager-orchestrated multi-agent swarm — auto-routes simple tasks to 2-agent loop, complex tasks to full pipeline"
argument-hint: "<task> [--keep-panes] [--agents <names>] [--dry-run] [--sequential] [--resume] [--skip-discuss]"
---

# /swarm — Multi-Agent Orchestration

> **allowed-tools**: `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Agent`, `TaskCreate`, `TaskUpdate`, `TaskList`, `Skill`, `AskUserQuestion`

<!-- Phase Flow (V2 complete):
  Phase 0: Init (mux detect, interrupted/stale detection, --resume, registry, session)
  Phase 1: Context detection + complexity classification
  Phase 1.5: PRE-EXECUTION DISCUSS (grey area batch table, --skip-discuss to bypass)
  Phase 2: Plan decomposition + WAVE GROUPING (dependency graph, cycle detection)
  Phase 3: Wave dispatch (parallel within wave, sequential across waves)
           └─ Between waves: REGRESSION CHECK (JUnit XML identity comparison)
  Phase 4: Review (holistic + optional Codex audit)
  Phase 5: VERIFICATION ROUTING (flaky pre-filter → passed/gaps_found/human_needed)
           └─ Gap closure: snapshot → fix tasks → regression check → re-verify (max 1 round)
  Phase 6: Done (report, cleanup, next steps)
-->

## Purpose

Execute tasks using a manager-orchestrated swarm of agents. Claude acts as the manager, dispatching work to Codex CLI (and future agents) via file-based messaging. Integrates with superpowers specs/plans when available.

## Argument Parsing

Parse `$ARGUMENTS`:
- `--keep-panes` → don't kill agent panes after completion
- `--agents <names>` → comma-separated agent names from registry (default: auto from role_priority)
- `--dry-run` → show plan + team composition without executing
- `--sequential` → force strict task-by-task ordering (disable wave parallelism)
- `--resume` → resume interrupted session instead of starting fresh
- `--skip-discuss` → skip Phase 1.5 grey area extraction
- Everything else → task description

## Phase 0: Prerequisites & Init

### 0.1 Source Transport Library

```bash
source ~/.claude/local-plugins/plugins/swarm/lib/swarm-transport.sh
```

### 0.2 Detect Multiplexer

```bash
MUX=$(swarm_detect_mux)
```

Report to user:
- `cmux` → "Running in CMUX — full visual panes + sidebar status"
- `tmux` → "Running in tmux — visual panes enabled"
- `none` → "No multiplexer detected — agents will run as background processes"

### 0.3 Check for Interrupted / Stale Sessions

```bash
INTERRUPTED=$(swarm_find_interrupted_sessions "$(pwd)")
STALE=$(swarm_find_stale_sessions "$(pwd)")
```

**If `--resume` AND interrupted session found:**
- Read the interrupted session's ledger and completed task results
- Present summary: "Found interrupted session [ID]. N of M tasks complete. Resume from wave W?"
- On user approval: reuse that session (set `SESSION_DIR` to it), skip to Phase 3 with only remaining tasks
- On user decline: proceed to fresh session

**If `--resume` but no interrupted session:**
- Warn: "No interrupted sessions found. Starting fresh."

**If no `--resume` but interrupted session exists:**
- Ask: "Found interrupted session [ID]. Resume it, or start fresh?"

**If stale sessions found (no progress):**
- Ask: "Found N stale swarm sessions. Clean up orphan panes? [Y/n]"
- If yes, call `swarm_cleanup` on each stale session directory.

### 0.4 Read Agent Registry

Read `~/.claude/local-plugins/plugins/swarm/agents.yaml`. Verify that at least one agent's command is available on PATH (e.g., `which codex`). Warn if missing.

### 0.5 Initialize Session

```bash
SESSION_ID=$(swarm_new_session "$(pwd)")
SESSION_DIR="$(pwd)/.swarm/${SESSION_ID}"
swarm_init_ledger "${SESSION_DIR}" "${SESSION_ID}" "${MUX}"
swarm_ensure_gitignore "$(pwd)"
```

Set CMUX sidebar (if available):
```bash
swarm_set_status "Swarm Leader"
swarm_set_progress "Init" "0.05"
```

## Phase 1: Context Detection & Complexity Classification

### 1.1 Check for Existing Superpowers Artifacts

Search for:
1. `docs/superpowers/specs/*-design.md` — recent design specs
2. `docs/superpowers/plans/*-plan.md` OR `.plans/*.md` — implementation plans

### 1.2 Route Based on Context

| Found | Action |
|-------|--------|
| Spec + plan | Read plan, decompose into work units → Phase 2 |
| Spec only | Invoke `Skill("superpowers:writing-plans")` → then Phase 2 |
| Nothing + complex task | Invoke `Skill("superpowers:brainstorming")` → then writing-plans → then Phase 2 |
| Nothing + simple task | Skip to Phase 3 (two-agent loop) |

### 1.3 Complexity Heuristic

**Simple** (two-agent loop — Claude + Codex):
- Task mentions 1-3 files or a single function/method
- Contains keywords: "fix", "typo", "rename", "update", "change"
- No mention of tests, architecture, or multiple components

**Complex** (full swarm with plan):
- Multiple components, files, or modules mentioned
- Contains keywords: "build", "implement", "add feature", "refactor", "system"
- Mentions tests, coverage, or multiple concerns

State your classification to the user and let them override.

## Phase 1.5: Pre-Execution Discuss (Grey Areas)

**Skip this phase when:** simple task (two-agent loop), `--skip-discuss` flag, or manager judges the plan has no ambiguous decisions.

After reading the plan (Phase 1.1) and before writing task files (Phase 2):

### 1.5.1 Scan for grey areas

Read the plan and identify decisions that are ambiguous or could go multiple ways:
- Technology choices ("use X or Y?")
- Data format decisions ("JSON vs YAML?", "REST vs GraphQL?")
- Scope boundaries ("include error handling for X?")
- Architecture decisions ("single file vs split?")
- Naming conventions unclear from spec

### 1.5.2 Present as batch table

Instead of asking one-by-one (slow), present 3-5 grey areas with recommendations:

```markdown
## Pre-Execution Decisions

| # | Grey Area | Recommendation | Alternative |
|---|-----------|---------------|-------------|
| 1 | Auth approach | JWT tokens | Session cookies |
| 2 | Config format | YAML (matches existing) | JSON |
| 3 | Error response shape | `{error, code, detail}` | `{message, status}` |

Accept all, or specify which to change?
```

### 1.5.3 Embed decisions

User responds: accept all (fast path) or override specific items.

Store resolved decisions for embedding into task files in Phase 2. Each task file will include a `## Decisions` section with grey areas relevant to that task.

If no grey areas found → skip silently, proceed to Phase 2.

## Phase 2: Plan Decomposition

Read the implementation plan and decompose into task files.

For each logical work unit in the plan:

1. Write `${SESSION_DIR}/tasks/task-NNN.md` with:
   ```markdown
   # Task NNN: [title]

   ## Context
   - Project: [pwd]
   - Branch: [current git branch]
   - Session: [session_id]
   - Wave: [assigned after grouping]

   ## Depends On
   - [task-NNN that must complete before this one, or empty]

   ## Files to Touch
   - [list of files this task will read or write]

   ## Decisions
   - [resolved grey areas from Phase 1.5, relevant to this task]

   ## Assignment
   [detailed description of what to implement]

   ## Acceptance Criteria
   - [what "done" means]

   ## Instructions
   Write your result to: [path to task-NNN.result]
   Format:
   - Status: DONE | FAILED
   - Files Changed: [list]
   - Summary: [what you did]
   - Issues: [any problems encountered]
   ```

2. After writing ALL task files, run wave grouping:
   ```bash
   WAVE_RESULT=$(swarm_group_waves "${SESSION_DIR}")
   WAVE_EXIT=$?
   ```

3. Handle wave grouping result:
   - **Exit 0 (success)**: Parse wave assignments, write wave number into each task's `## Context` section, update ledger `wave_count`.
   - **Exit 2 (cycle detected)**: Present the cycle to the user. Ask them to resolve the circular dependency by rewriting task boundaries. Do NOT proceed to Phase 3.

4. If `--sequential` flag: override all wave assignments to sequential (wave N = task N).

5. Update ledger:
   ```bash
   swarm_update_ledger_field "${SESSION_DIR}" "tasks_total" "N"
   swarm_update_ledger_field "${SESSION_DIR}" "wave_count" "W"
   ```

If `--dry-run`: present the task list with wave assignments and team composition, then stop.

```bash
swarm_set_progress "Planning" "0.15"
```

## Phase 3: Execute

### 3.1 Regression Baseline (lazy)

Only capture baseline when `wave_count > 1`:
```bash
if (( WAVE_COUNT > 1 )); then
  GATE_STATUS=$(swarm_capture_test_baseline "${SESSION_DIR}")
  swarm_update_ledger_field "${SESSION_DIR}" "regression_gate" "${GATE_STATUS}"
  if [[ "${GATE_STATUS}" == "unavailable" ]]; then
    # Warn user but continue — regression gate degrades gracefully
    echo "Warning: Test baseline capture failed. Regression gate disabled for this session."
  fi
fi
```

### 3.2 Spawn Agent(s)

Read the agent registry (`~/.claude/local-plugins/plugins/swarm/agents.yaml`).
Each agent has two command modes:
- `command_interactive`: long-lived REPL for pane mode (tmux/cmux) — receives tasks via terminal I/O
- `command_exec`: one-shot per task — runs, produces result, exits

**Pane mode (tmux/cmux):** Spawn interactive agent, send tasks via terminal:
```bash
CODEX_PANE=$(swarm_spawn_agent "Codex" "codex" "$(pwd)" "${SESSION_DIR}")
swarm_register_agent "${SESSION_DIR}" "Codex" "${CODEX_PANE}" "coder"
```

**Headless mode (none):** Don't pre-spawn. Run `command_exec` per task (see 3.3).

```bash
swarm_set_progress "Executing" "0.25"
```

### 3.3 Wave Dispatch Loop

Group tasks by wave number. Execute waves sequentially; within each wave, dispatch tasks in parallel.

```
For each wave W (1, 2, ... WAVE_COUNT):

  1. Collect all tasks assigned to wave W

  2. For each task in wave W, dispatch simultaneously:

     Before dispatch: clear stale results:
     swarm_clear_result "${SESSION_DIR}/tasks/task-NNN.md"

     Pane mode (tmux/cmux) — pipe to interactive agent:
     swarm_pipe_prompt "${CODEX_PANE}" "Read and implement the task at ${SESSION_DIR}/tasks/task-NNN.md — write result to task-NNN.result with a 'Status: DONE' or 'Status: FAILED' line."

     Headless mode (none) — one-shot exec per task:
     codex exec "$(cat ${SESSION_DIR}/tasks/task-NNN.md). Write your result summary to ${SESSION_DIR}/tasks/task-NNN.result. Start with 'Status: DONE' or 'Status: FAILED', then Files Changed and Summary sections."

  3. Poll all results in wave W concurrently:
     swarm_poll_result "${SESSION_DIR}/tasks/task-NNN.md" 300

  4. Evaluate results for wave W:
     - Status: DONE → accept
     - Status: FAILED → swarm_clear_result, retry with clarified prompt (max 2 retries per task)
     - Timeout → escalate to user

  5. Update progress:
     swarm_update_ledger_field "${SESSION_DIR}" "tasks_done" "N"
     swarm_set_progress "Wave W — Task N/Total" "0.${progress}"

  6. Between-wave regression check (if wave_count > 1 AND regression_gate == "baseline"):
     REGRESSED=$(swarm_check_regression "${SESSION_DIR}" "${W}")
     if [[ $? -eq 1 ]]; then
       # Regression detected — create targeted fix task
       echo "Regression detected after wave ${W}: ${REGRESSED}"
       # Correlate with files changed: git diff --stat
       # Create fix task → dispatch to agent → re-check
       # Max 1 regression-fix attempt per wave. If still regressed → escalate.
     fi
```

### 3.4 Claude Subagent Dispatch (parallel work)

For tasks that benefit from Claude's tools (research, test writing, refactoring):

```
Agent(
  name="task-NNN-worker",
  prompt="Implement this task: [task content]. When done, write a summary to [result path].",
  subagent_type="general-purpose"
)
```

This runs as a Claude Code subagent — no pane needed, uses native Agent tool.

### 3.5 Simple Task Path (two-agent loop)

**For simple tasks (two-agent loop):**
- Skip task file creation and wave grouping
- Claude implements directly, then delegates review to Codex using `command_exec` from registry:
  ```bash
  codex exec "Review the changes in $(git diff --stat). Focus on correctness, edge cases, security. Write findings to ${SESSION_DIR}/reviews/review-001.result. Start with 'Status: DONE' or 'Status: NEEDS_REVISION'."
  ```
- Before each retry: `swarm_clear_result` on the review file
- Iterate if NEEDS_REVISION (max 3 rounds)

## Phase 4: Review

After all tasks complete:

1. **Holistic review** — Manager (Claude) reads all `.result` files, checks for:
   - Consistency across task outputs
   - Integration issues between components
   - Missing tests or error handling

2. **Codex audit** (optional for complex tasks):
   Write review request to `${SESSION_DIR}/reviews/review-final.md`:
   ```markdown
   # Final Audit Request
   
   ## Changes Summary
   [aggregated from all task results]
   
   ## Review Focus
   - Cross-component consistency
   - Security vulnerabilities
   - Test coverage gaps
   ```

   Dispatch to Codex, wait for `.result`.

3. **Fix loop** — if review finds issues:
   - Create fix tasks → dispatch → poll → max 3 rounds
   - If still failing after 3 rounds → escalate to user

```bash
swarm_set_progress "Reviewing" "0.75"
```

## Phase 5: Verification Routing

### 5.1 Run automated checks

```bash
# Full test suite with detail
pytest --tb=short 2>&1 | tee "${SESSION_DIR}/verify-pytest.txt"
PYTEST_EXIT=$?

# Git state
git diff --stat > "${SESSION_DIR}/verify-git-diff.txt"
git status --short > "${SESSION_DIR}/verify-git-status.txt"
```

Read all `.result` files. Check: are all tasks DONE? Does the output cover the original plan/spec?

### 5.2 Flaky test pre-filter

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

### 5.3 Classify verification state

| State | Condition | Action |
|---|---|---|
| `passed` | All deterministic tests green + all tasks DONE + plan fully covered | Auto-proceed to Phase 6 |
| `gaps_found` | Deterministic test failures OR any task FAILED OR plan coverage incomplete | Gap closure cycle (5.4) |
| `human_needed` | All automated checks pass but items need manual verification, OR infrastructure/flaky failures detected | Present targeted checklist to user, continue on approval |

```bash
swarm_update_ledger_field "${SESSION_DIR}" "verification_state" "${STATE}"
swarm_set_progress "Verified: ${STATE}" "0.9"
```

### 5.4 Gap closure cycle (when `gaps_found`)

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

### 5.5 Human-needed checklist

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

## Phase 6: Done

1. **Generate report** to `${SESSION_DIR}/report.md`:
   ```markdown
   # Swarm Report
   
   Session: [session_id]
   Task: [original task description]
   Duration: [elapsed time]
   Agents: [list with pane refs]
   Mux: [cmux|tmux|none]
   
   ## Tasks Completed
   - task-001: [title] — DONE
   - task-002: [title] — DONE
   
   ## Files Changed
   [aggregated list]
   
   ## Test Results
   [pass/fail summary]
   
   ## Review Findings
   [any issues found and resolved]
   ```

2. **Cleanup panes** (unless `--keep-panes`):
   ```bash
   swarm_cleanup "${SESSION_DIR}"
   ```

3. **Present report** to user.

4. **Offer next steps:**
   - "Commit these changes?" → if yes, create conventional commit
   - "Run superpowers:verification-before-completion?" → final gate
   - "Create PR?" → invoke finishing-a-development-branch

```bash
swarm_set_progress "Complete" "1.0"
swarm_log "success" "Swarm complete — ${TASKS_DONE} tasks executed"
```

## Error Handling

| Scenario | Action |
|----------|--------|
| Agent command not found | Warn user, fall back to Claude-only (Agent tool) |
| Agent timeout (5min) | Retry with simplified prompt (1 retry) |
| Agent crash (pane dies) | Detect via `swarm_check_agent_alive`, report to user |
| `.result` malformed | Ask agent to rewrite (1 retry) |
| All external agents fail | Fall back to Claude subagents only |
| Cycle detected in wave grouping | Halt, present cycle to user for resolution |
| Regression detected between waves | Create fix task, dispatch, re-check (max 1 fix per wave) |
| Regression gate baseline unavailable | Continue without between-wave checks, warn in report |
| Flaky tests detected | Exclude from gap analysis, flag in report, route to `human_needed` |
| Infrastructure test failure | Route to `human_needed` (not auto-fix) |
| Gap closure introduces regression | Include in escalation diagnosis |
| Tests fail after gap closure | Escalate to user with full diagnosis |
| Stale session found on init | Offer cleanup |
| Interrupted session found | Offer resume (or auto-resume with `--resume`) |
| `--resume` but no interrupted session | Warn and start fresh |
| Grey areas found in plan | Present batch table, embed decisions in tasks |
| No grey areas in plan | Skip Phase 1.5 silently |
