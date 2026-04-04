---
description: "Manager-orchestrated multi-agent swarm — auto-routes simple tasks to 2-agent loop, complex tasks to full pipeline"
argument-hint: "<task> [--keep-panes] [--agents <names>] [--dry-run] [--sequential] [--resume] [--skip-discuss]"
---

# /swarm — Multi-Agent Orchestration

> **allowed-tools**: `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Agent`, `TaskCreate`, `TaskUpdate`, `TaskList`, `Skill`, `AskUserQuestion`

> **HARD RULE — NO MCP TOOLS FOR AGENT DISPATCH**: NEVER use `mcp__codex__codex`, `mcp__gemini__*`, or any MCP server tool to dispatch work to agents. ALL agent interaction MUST go through the transport lib: `swarm_spawn_agent` (spawn in pane), `swarm_pipe_prompt` (send work), `swarm_poll_result` (get results). Using MCP tools bypasses the visual pane orchestration and is a protocol violation.

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
- On user approval: reuse that session (set `SESSION_DIR` to it), record the resume:
  ```bash
  swarm_update_ledger_field "${SESSION_DIR}" "resumed_from" "${INTERRUPTED_SESSION_ID}"
  ```
  Skip to Phase 3 with only remaining tasks.
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
PRE_SWARM_SHA=$(git rev-parse HEAD)  # anchor for Phase 4 review diff
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

### 1.1.1 Parallel Context Gathering (complex tasks only)

Before invoking brainstorming for complex tasks, dispatch up to 3 parallel SDD exploration subagents to accelerate context gathering:

```
Agent(subagent_type="Explore", name="arch-scan", prompt="Scan codebase architecture: directory structure, key modules, tech stack, entry points")
Agent(subagent_type="Explore", name="pattern-scan", prompt="Find similar patterns for [task description]: analogous implementations, conventions, reusable utilities")
Agent(subagent_type="Explore", name="test-scan", prompt="Identify test patterns: framework, fixture conventions, coverage areas, how to verify [task description]")
```

Feed findings into brainstorming/planning. Skip for simple tasks.

### 1.2 Route Based on Context

| Found | Action |
|-------|--------|
| Spec + plan | Read plan, decompose into work units → Phase 2 |
| Spec only | Invoke `Skill("superpowers:writing-plans")` → then Phase 2 |
| Nothing + complex task | Run 1.1.1 parallel research → `Skill("superpowers:brainstorming")` → writing-plans → Phase 2 |
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

**Pane mode (tmux/cmux):** Spawn one pane per parallel task using grid layout.
Use `command_interactive` from registry. For multi-agent grids:
- Agent 1: `split_dir="right"` (splits from main)
- Agent 2: `split_dir="down"` from Agent 1 (top-right → 2 rows on right)
- Agent 3: `split_dir="down"` from main (bottom-left)
- Agent 4: `split_dir="right"` from Agent 3 (bottom-right)
- Agent N: continue grid pattern

```bash
# Example: 4-agent grid
PANE1=$(swarm_spawn_agent "Agent-1" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "right")
PANE2=$(swarm_spawn_agent "Agent-2" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "down" "${PANE1}")
PANE3=$(swarm_spawn_agent "Agent-3" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "down")
PANE4=$(swarm_spawn_agent "Agent-4" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "right" "${PANE3}")
swarm_register_agent "${SESSION_DIR}" "Agent-N" "${PANE_N}" "coder"
```

**Headless mode (none):** Don't pre-spawn. Run `command_exec` per task (see 3.3).

**Model routing** (for agents with `supports_model_routing: true`):
Read `model_routing` from registry. For each task, classify complexity by keywords + file count:
- `simple` → append `--model haiku` (e.g., fixes, renames, single-file changes)
- `standard` → append `--model sonnet` (e.g., implement, create, build)
- `complex` → append `--model opus` (e.g., refactor, architect, security)

For interactive panes: model is set at spawn time, so classify the WAVE's overall complexity.
For exec mode: model is set per-task invocation.

```bash
swarm_set_progress "Executing" "0.25"
```

**Codex internal SDD:** When Codex is the coder in a pane, it has access to the full Superpowers skill set (`~/.codex/skills/`), including SDD, TDD, and code-review. Codex manages its own internal subagent dispatch via `multi_agent = true` (max 6 threads: explorer, reviewer, docs_researcher, worker). The orchestrator does not need to manage Codex's internal parallelism — just dispatch the task and poll for the result.

### 3.2.1 Dispatch Method Selection

For each task, choose the dispatch method. The orchestrator uses whichever is appropriate — not one-size-fits-all.

| Condition | Method | Why |
|-----------|--------|-----|
| `--agents codex/gemini` (explicit) | **Pane** | Cross-model requires CLI pane |
| Complex task (opus-level) | **Pane** | Visual feedback for long-running work |
| Simple/standard + same model (no `--agents` flag) | **SDD subagent** | Faster, no startup overhead |
| MUX=none + no external CLI | **SDD subagent** | Only option available |

**Pane dispatch:** Use `swarm_spawn_agent` → `swarm_pipe_prompt` → `swarm_poll_result` (transport lib).

**SDD subagent dispatch:** Use `Agent` tool with the SDD implementer-prompt template. Subagent reports status (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT) and writes to the same `.result` file format.

### 3.3 Wave Dispatch Loop

Group tasks by wave number. Execute waves sequentially; within each wave, dispatch tasks in parallel.

```
For each wave W (1, 2, ... WAVE_COUNT):

  1. Collect all tasks assigned to wave W

  2. For each task in wave W, dispatch simultaneously:

     Before dispatch: clear stale results:
     swarm_clear_result "${SESSION_DIR}/tasks/task-NNN.md"

     Model routing (Claude agents only, when supports_model_routing: true):
     MODEL=$(swarm_classify_task "${SESSION_DIR}/tasks/task-NNN.md")
     # MODEL = haiku | sonnet | opus

     Pane mode (tmux/cmux) — pipe to interactive agent:
     swarm_pipe_prompt "${AGENT_PANE}" "Read and implement the task at ${SESSION_DIR}/tasks/task-NNN.md — write result to task-NNN.result with a 'Status: DONE' or 'Status: FAILED' line."

     Headless mode (none) — one-shot exec per task:
     For Claude agents: claude --dangerously-skip-permissions --model ${MODEL} -p "$(cat ${SESSION_DIR}/tasks/task-NNN.md). Write result to task-NNN.result."
     For Codex agents: codex exec "$(cat ${SESSION_DIR}/tasks/task-NNN.md). Write result to task-NNN.result."
     For other agents: use command_exec from registry.

  3. Poll all results in wave W concurrently:
     swarm_poll_result "${SESSION_DIR}/tasks/task-NNN.md" 300

  4. Evaluate results for wave W (SELF-CORRECTIVE LOOP):

     For each completed task in this wave, run the quality evaluation loop.
     This is NOT optional — the orchestrator MUST evaluate every task result.

     ```bash
     # Step A: Check result status
     STATUS=$(swarm_check_result_status "${SESSION_DIR}/tasks/task-NNN.result")

     # Step B: Get acceptance criteria from original task
     CRITERIA=$(swarm_get_acceptance_criteria "${SESSION_DIR}/tasks/task-NNN.md")

     # Step C: Get files the agent changed
     CHANGED=$(swarm_get_files_changed "${SESSION_DIR}/tasks/task-NNN.result")
     ```

     **Step D: Read and evaluate (orchestrator judgment)**
     For each file in CHANGED, READ the actual file content.
     Compare against each line in CRITERIA. For each criterion, mark PASS or FAIL.
     This is the critical step — do not skip it.

     **Step E: Route based on evaluation**

     | Evaluation | Condition | Action |
     |-----------|-----------|--------|
     | **ACCEPT** | STATUS=DONE AND all criteria PASS | Mark complete, move on |
     | **REVISE** | STATUS=DONE BUT 1+ criteria FAIL | Create revision task (below) |
     | **RETRY** | STATUS=FAILED or MALFORMED | `swarm_clear_result`, retry same task (max 2) |
     | **TIMEOUT** | STATUS=MISSING after poll timeout | Escalate to user |
     | **ESCALATE** | 2 revisions exhausted, still failing | Flag to user with diagnosis |

     **REVISE flow (max 2 rounds per task):**
     ```bash
     # Loop until accepted or max revisions exhausted
     while swarm_can_revise "${SESSION_DIR}" "task-NNN"; do
       NEXT_REV=$(swarm_next_revision_num "${SESSION_DIR}" "task-NNN")
       REV_FILE=$(swarm_write_revision_task "${SESSION_DIR}" "task-NNN" "${NEXT_REV}" \
         "${ISSUES_DESCRIPTION}") || { echo "ERROR: revision task creation failed"; break; }
       # Dispatch revision to the SAME agent pane
       swarm_pipe_prompt "${AGENT_PANE}" "Read and fix the issues in: ${REV_FILE}"
       # Poll for revision result
       swarm_poll_result "${REV_FILE}" 300
       # Re-evaluate: run Steps A-E on the REVISION result
       STATUS=$(swarm_check_result_status "${REV_FILE%.md}.result")
       if [[ "${STATUS}" != "DONE" ]]; then
         swarm_record_revision_progress "${SESSION_DIR}" "task-NNN" "${NEXT_REV}" "0/${TOTAL_CRITERIA} passed (${STATUS})"
         continue  # FAILED/MALFORMED → try another revision
       fi
       # STATUS is DONE — but MUST re-check acceptance criteria (Step D)
       # Read the actual files changed, compare against CRITERIA
       # Count passing criteria: PASSED_COUNT / TOTAL_CRITERIA
       swarm_record_revision_progress "${SESSION_DIR}" "task-NNN" "${NEXT_REV}" "${PASSED_COUNT}/${TOTAL_CRITERIA} passed"
       # Check convergence before continuing
       CONVERGENCE=$(swarm_check_revision_convergence "${SESSION_DIR}" "task-NNN")
       if [[ "${CONVERGENCE}" == "stalled" ]]; then
         # Not making progress — escalate early instead of wasting a revision
         echo "Revision stalled for task-NNN (no improvement). Escalating."
         break
       fi
       # If all criteria PASS → break (task accepted)
       # If criteria still FAIL → update ISSUES_DESCRIPTION and continue loop
       # DO NOT break here without re-evaluating criteria.
       # The orchestrator MUST read the code again at this point.
     done
     # If loop exhausted (swarm_can_revise returned false): escalate to user
     ```

     **The revision task includes the FULL original task** (not just criteria).
     `swarm_write_revision_task` embeds the entire original task-NNN.md content
     so the agent has full context for the fix.

     **What "ISSUES_DESCRIPTION" must contain (non-negotiable):**
     - Which acceptance criterion failed and why
     - File path + line number where the problem is
     - What the code does vs what it should do
     - Concrete fix instruction (not vague "improve error handling")

     **Validation:** If you cannot point to a specific file:line with a concrete
     problem, the task PASSES. Do not revise on vague feelings. "Could be better"
     is not an issue. "Line 15 catches Exception instead of ValueError" is.

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

### 3.4 Claude Subagent Dispatch (fallback only)

**Only use when:** no multiplexer available (MUX=none) AND no external CLI agent available.
Prefer CMUX/tmux panes (3.2) or headless exec (3.3) — subagents are invisible to the user.

```
Agent(
  name="task-NNN-worker",
  prompt="Implement this task: [task content]. When done, write a summary to [result path].",
  subagent_type="general-purpose"
)
```

This runs as a Claude Code subagent — no pane, no visual feedback. Last resort only.

### 3.5 Simple Task Path (two-agent loop)

**For simple tasks:**
- Skip task file creation and wave grouping
- Select coder based on dispatch method (3.2.1):
  - If `--agents codex` forced → spawn Codex in pane, Opus reviews
  - Otherwise → Claude implements directly or via SDD subagent (follows implementer-prompt.md template)
    - SDD subagent reports: DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT
    - Handle NEEDS_CONTEXT by providing info and re-dispatching
    - Handle BLOCKED by escalating to user
- Cross-review: spawn Codex in a CMUX pane to review (coder=Claude) or Opus reviews via two-stage SDD (coder=Codex, see 4.3b)
- Before each retry: `swarm_clear_result` on the review file
- Iterate if NEEDS_REVISION (max 3 rounds)

## Phase 4: Review

**Cross-review rule:** The reviewer must be a different agent than the coder.

| Coder Agent | Reviewer | How |
|-------------|----------|-----|
| Claude (any model) | Codex | `codex review` or `codex exec` with review prompt |
| Codex | Claude Opus (orchestrator) | Invoke `Skill("superpowers:requesting-code-review")` → spawns `superpowers:code-reviewer` subagent |
| Gemini | Codex | `codex review` or `codex exec` with review prompt |

After all tasks complete:

### 4.1 Determine reviewer (with pre-flight validation)

Read the `--agents` flag used in this session. Select reviewer per the table above.

**Pre-flight check (mandatory):** Before dispatching any review, validate that the selected coder and reviewer are not the same agent type. Specifically:
- If `--agents codex,codex` or any configuration where all coders and the reviewer resolve to the same agent type → **WARN the user**: "Cross-review violation: coder and reviewer are the same agent ([agent]). Reviews by the same agent that wrote the code provide weaker guarantees. Override? [Y/n]"
- If user declines override → fall back to Claude Opus orchestrator as reviewer (always available).
- Two Claude variants (e.g., Claude Sonnet coding, Claude Opus reviewing) are acceptable — the cross-review rule applies to the agent *identity*, not the model.

### 4.2 Prepare review context

```bash
# PRE_SWARM_SHA was captured at Phase 0.5 init:
#   PRE_SWARM_SHA=$(git rev-parse HEAD)
# If not set, fall back to HEAD~1
BASE_SHA="${PRE_SWARM_SHA:-$(git rev-parse HEAD~1)}"
HEAD_SHA=$(git rev-parse HEAD)
```

Aggregate from all `.result` files: files changed, summaries, what was implemented.

### 4.3a Codex reviews (when coder was Claude or Gemini)

Spawn Codex in a CMUX pane (or exec mode) with review prompt:

```bash
codex exec "Review the code changes between ${BASE_SHA}..${HEAD_SHA}.
Focus on: correctness, edge cases, security, test coverage, cross-component consistency.
Write findings to ${SESSION_DIR}/reviews/review-final.result.
Format: Status: DONE or Status: NEEDS_REVISION, then Strengths, Issues (Critical/Important/Minor), Assessment."
```

Poll for `review-final.result`.

### 4.3b Claude Opus reviews (when coder was Codex) — Two-Stage SDD Review

**Stage 1 — Spec compliance** (run first):

Dispatch a subagent using the SDD spec-reviewer-prompt template:

```
Agent(
  subagent_type="superpowers:code-reviewer",
  prompt="[spec-reviewer-prompt.md template filled with:
    - FULL TEXT of task acceptance criteria
    - Implementer's result report
    - Instructions: Read actual code, do NOT trust the report.
      Compare implementation to each criterion line by line.
      Output: ✅ compliant or ❌ issues with file:line references]"
)
```

If spec review finds issues → route back to coder for fixes (Phase 4.4). Do NOT proceed to Stage 2.

**Stage 2 — Code quality** (only if Stage 1 passes):

Invoke `Skill("superpowers:requesting-code-review")` with:
- `{WHAT_WAS_IMPLEMENTED}`: aggregated task summaries
- `{PLAN_OR_REQUIREMENTS}`: original plan/spec or task description
- `{BASE_SHA}`: pre-swarm commit
- `{HEAD_SHA}`: current HEAD
- `{DESCRIPTION}`: swarm session summary

The skill spawns a `superpowers:code-reviewer` subagent that reviews the diff and returns structured feedback (Strengths, Critical/Important/Minor issues, Assessment).

**Why two stages:** Spec compliance is fast and binary (did they build what was asked?). Code quality is deeper (is it well-built?). Running quality review on non-compliant code wastes effort.

### 4.4 Fix loop

Act on reviewer feedback:
- **Critical** → create fix tasks, dispatch to coder agents, re-review (max 3 rounds)
- **Important** → create fix tasks, dispatch (same loop)
- **Minor** → note in report, do not block

If still failing after 3 rounds → escalate to user.

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
