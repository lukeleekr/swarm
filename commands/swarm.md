---
description: "Manager-orchestrated multi-agent swarm — auto-routes simple tasks to 2-agent loop, complex tasks to full pipeline"
argument-hint: "<task> [--keep-panes] [--agents <names>] [--dry-run] [--parallel]"
---

# /swarm — Multi-Agent Orchestration

> **allowed-tools**: `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Agent`, `TaskCreate`, `TaskUpdate`, `TaskList`, `Skill`, `AskUserQuestion`

## Purpose

Execute tasks using a manager-orchestrated swarm of agents. Claude acts as the manager, dispatching work to Codex CLI (and future agents) via file-based messaging. Integrates with superpowers specs/plans when available.

## Argument Parsing

Parse `$ARGUMENTS`:
- `--keep-panes` → don't kill agent panes after completion
- `--agents <names>` → comma-separated agent names from registry (default: auto from role_priority)
- `--dry-run` → show plan + team composition without executing
- `--sequential` → force strict task-by-task ordering (disable wave parallelism)
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

### 0.3 Check for Stale Sessions

```bash
STALE=$(swarm_find_stale_sessions "$(pwd)")
```

If stale sessions found, ask user: "Found N stale swarm sessions. Clean up orphan panes? [Y/n]"
If yes, call `swarm_cleanup` on each stale session directory.

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

### 3.1 Spawn Agent(s)

Read the agent registry (`~/.claude/local-plugins/plugins/swarm/agents.yaml`).
Each agent has two command modes:
- `command_interactive`: long-lived REPL for pane mode (tmux/cmux) — receives tasks via terminal I/O
- `command_exec`: one-shot per task — runs, produces result, exits

**Pane mode (tmux/cmux):** Spawn interactive agent, send tasks via terminal:
```bash
# Use command_interactive from registry (e.g., "codex" not "codex exec")
CODEX_PANE=$(swarm_spawn_agent "Codex" "codex" "$(pwd)" "${SESSION_DIR}")
swarm_register_agent "${SESSION_DIR}" "Codex" "${CODEX_PANE}" "coder"
```

**Headless mode (none):** Don't pre-spawn. Run `command_exec` per task (see 3.2).

```bash
swarm_set_progress "Executing" "0.25"
```

### 3.2 Task Dispatch Loop

For each task (respecting dependency order):

**Before each retry:** clear stale results:
```bash
swarm_clear_result "${SESSION_DIR}/tasks/task-NNN.md"
```

1. **Dispatch task to agent:**

   **Pane mode (tmux/cmux)** — pipe to interactive agent:
   ```bash
   swarm_pipe_prompt "${CODEX_PANE}" "Read and implement the task at ${SESSION_DIR}/tasks/task-NNN.md — write result to task-NNN.result with a 'Status: DONE' or 'Status: FAILED' line."
   ```

   **Headless mode (none)** — one-shot exec per task:
   ```bash
   # Read command_exec from registry (e.g., "codex exec")
   codex exec "$(cat ${SESSION_DIR}/tasks/task-NNN.md). Write your result summary to ${SESSION_DIR}/tasks/task-NNN.result. Start with 'Status: DONE' or 'Status: FAILED', then Files Changed and Summary sections."
   ```

2. **Poll for result:**
   ```bash
   swarm_poll_result "${SESSION_DIR}/tasks/task-NNN.md" 300
   ```
   Result is only accepted when file exists, is non-empty, AND contains a `Status:` marker line.

3. **Read and evaluate result:**
   - Status: DONE → accept, move to next task
   - Status: FAILED → `swarm_clear_result`, retry with clarified prompt (max 2 retries)
   - Timeout → escalate to user

4. **Update progress:**
   ```bash
   swarm_update_ledger_field "${SESSION_DIR}" "tasks_done" "N"
   swarm_set_progress "Task N/Total" "0.${progress}"
   ```

**Parallel dispatch** (when tasks are independent or `--parallel`):
- Dispatch all independent tasks simultaneously
- Poll for all results concurrently
- Proceed to dependent tasks only after dependencies complete

**For simple tasks (two-agent loop):**
- Skip task file creation
- Claude implements directly, then delegates review to Codex using `command_exec` from registry:
  ```bash
  # Uses command_exec from agents.yaml (e.g., "codex exec")
  codex exec "Review the changes in $(git diff --stat). Focus on correctness, edge cases, security. Write findings to ${SESSION_DIR}/reviews/review-001.result. Start with 'Status: DONE' or 'Status: NEEDS_REVISION'."
  ```
- Before each retry: `swarm_clear_result` on the review file
- Iterate if NEEDS_REVISION (max 3 rounds)

### 3.3 Claude Subagent Dispatch (parallel work)

For tasks that benefit from Claude's tools (research, test writing, refactoring):

```
Agent(
  name="task-NNN-worker",
  prompt="Implement this task: [task content]. When done, write a summary to [result path].",
  subagent_type="general-purpose"
)
```

This runs as a Claude Code subagent — no pane needed, uses native Agent tool.

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

## Phase 5: Verify

1. **Run tests:**
   ```bash
   pytest --tb=short 2>&1 | tail -20
   ```

2. **Check git state:**
   ```bash
   git diff --stat
   git status
   ```

3. **Sanity check** — Manager reads the original task/plan and confirms the output matches.

If tests fail → create fix task → dispatch → retry verification (max 2 rounds).

```bash
swarm_set_progress "Verifying" "0.9"
```

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
| Tests fail after 2 fix rounds | Escalate to user with diagnosis |
| Stale session found on init | Offer cleanup |
