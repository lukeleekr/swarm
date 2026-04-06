# Phase 3: Execute (Wave Dispatch + Single-Coder Path)

> Loaded by `SKILL.md` Phase 3 pointer. Contains the full execution implementation: regression baseline, agent spawn (pane vs subagent vs Native AgentTeam), wave dispatch loop with REVISE flow, conversation termination, fallback dispatch, and the Tier 2 single-coder path.

## 3.1 Regression Baseline (lazy)

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

## 3.2 Spawn Agent(s)

Read the agent registry (`~/.claude/local-plugins/plugins/swarm/agents.yaml`).
Each agent has two command modes:
- `command_interactive`: long-lived REPL for pane mode (tmux/cmux) — receives tasks via terminal I/O
- `command_exec`: one-shot per task — runs, produces result, exits

**Pane mode (tmux/cmux):** Spawn one pane per parallel task in a grid.

> **⚠️ Critical for tmux users:** Pane IDs stored as bash vars (`$PANE1`) do NOT
> survive across Bash tool invocations — each Bash call is a fresh shell. Either:
> (a) do all spawn + pipe + poll for a wave inside ONE Bash invocation, or
> (b) persist pane IDs to `${SESSION_DIR}/ledger.yaml` and re-read them each call.
> The lib's `swarm_register_agent` writes pane_id into the ledger; read it back
> with `grep 'pane_id:' ${SESSION_DIR}/ledger.yaml | awk '{print $2}'`.

> **⚠️ tmux sidebar limitation:** `swarm_set_status`, `swarm_set_progress`, and
> `swarm_log` are no-ops under tmux (cmux-only). Progress reporting in tmux
> happens via text output and the report file only.

For multi-agent grids, spawn sequence matters because the first `split_dir="right"`
with no `split_from` splits the **currently active** pane (the orchestrator), not
"from main." To get a predictable layout:

> **MANDATORY for any spawn batch with N≥2 new panes:** Immediately after the spawn
> loop completes (and before piping prompts), call:
>
> ```bash
> tmux select-layout tiled 2>/dev/null || true
> ```
>
> This rebalances all panes (including the orchestrator) into a roughly square grid.
> Without this, N successive `split_dir="right"` calls produce N thin vertical columns
> stacked next to the orchestrator, which is unreadable. Call again after killing panes
> to rebalance the survivors. The `2>/dev/null || true` makes it a no-op outside tmux
> (cmux/none) so it's safe to call unconditionally.

```bash
# Example: 4-agent grid (all spawns in ONE Bash invocation)
PANE1=$(swarm_spawn_agent "Agent-1" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "right")
PANE2=$(swarm_spawn_agent "Agent-2" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "down" "${PANE1}")
PANE3=$(swarm_spawn_agent "Agent-3" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "right" "${PANE1}")
PANE4=$(swarm_spawn_agent "Agent-4" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "down" "${PANE3}")
swarm_register_agent "${SESSION_DIR}" "Agent-1" "${PANE1}" "coder"
swarm_register_agent "${SESSION_DIR}" "Agent-2" "${PANE2}" "coder"
swarm_register_agent "${SESSION_DIR}" "Agent-3" "${PANE3}" "coder"
swarm_register_agent "${SESSION_DIR}" "Agent-4" "${PANE4}" "coder"
# Normalize layout for consistent 2x2 appearance
tmux select-layout tiled 2>/dev/null || true

# Wait for all panes in parallel — sequential is 30s × N worst case
for p in "${PANE1}" "${PANE2}" "${PANE3}" "${PANE4}"; do
  swarm_wait_agent_ready "${p}" 45 &
done
wait
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

## 3.2.1 Dispatch Method Selection

For each task, choose the dispatch method. The orchestrator uses whichever is appropriate — not one-size-fits-all.

| Condition | Method | Why |
|-----------|--------|-----|
| `--agents codex` (explicit) | **Pane** | Cross-model requires CLI pane |
| Complex task (opus-level) | **Pane** | Visual feedback for long-running work |
| Simple/standard + same model (no `--agents` flag) | **SDD subagent** | Faster, no startup overhead |
| MUX=none + no external CLI | **SDD subagent** | Only option available |

**Pane dispatch:** Use `swarm_spawn_agent` → `swarm_pipe_prompt` → `swarm_poll_result` (transport lib).

**SDD subagent dispatch:** Use `Agent` tool with the SDD implementer-prompt template. Subagent reports status (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT) and writes to the same `.result` file format.

## 3.2.2 Tier 3 / Claude Parallel — Native AgentTeam dispatch

When Phase 0.0 selected **Tier 3 with `--agents claude`**, use **Native AgentTeam** instead of bash-spawned `claude --dangerously-skip-permissions` panes. Native AgentTeam (`TeamCreate` + `Agent(team_name=...)`) provides smooth pane spawning without trust-prompt scraping or CLI cold-start — this is exactly the "absorb AgentTeam advantage" the smart router promises.

**One-time per session — create the team:**

```
TeamCreate({team_name: "swarm-${SESSION_ID}", description: "Tier-3 Claude parallel coders"})
```

**Per teammate — spawn as a Claude tmux pane:**

```
Agent(
  subagent_type="general-purpose",
  team_name="swarm-${SESSION_ID}",
  name="Coder-1",
  prompt="Implement the task at ${SESSION_DIR}/tasks/task-001.md. Use superpowers:subagent-driven-development for the implementation discipline. Write your result to ${SESSION_DIR}/tasks/task-001.result with Status: DONE/PARTIAL/NEEDS_HELP/FAILED, files changed, summary."
)
Agent(
  subagent_type="general-purpose",
  team_name="swarm-${SESSION_ID}",
  name="Coder-2",
  prompt="..."
)
# ... one Agent call per parallel task
```

Each teammate is a Claude process in its own tmux pane, mailbox-wired to Opus. The `prompt` parameter IS the dispatch — no `swarm_pipe_prompt` needed.

**Polling:** Native AgentTeam delivers teammate completion via mailbox notifications back to Opus (delivered as conversation turns automatically — do not poll). Read `.result` files written by each teammate per the SDD result format.

**Cleanup after wave completes:**

```
SendMessage({to: "Coder-1", message: {type: "shutdown_request"}})
# wait for shutdown_approved + teammate_terminated notifications
TeamDelete()
```

**Cross-model still applies:** the Codex plan reviewer (Phase 2.5) and the Codex code reviewer (Phase 4.3a) still use the bash transport (`swarm_spawn_agent`) — Native AgentTeam cannot host Codex.

**Why not bash-spawn `claude` panes for Tier 3?** Because Native AgentTeam is the harness's first-class API for spawning Claude teammates. Bash-spawning `claude --dangerously-skip-permissions` would re-pay the trust-prompt and CLI cold-start tax that swarm's transport library was built to absorb for *Codex*. Claude doesn't need that workaround — use the native API.

> **CONSTRAINT — Native AgentTeam is top-level only:** The `Agent(team_name=...)` tool required for spawning Claude teammates is **only exposed to the top-level Claude Code orchestrator session**, not to general-purpose subagents. `TeamCreate`, `SendMessage`, and `TeamDelete` ARE available to subagents, but the spawn step is not. This means:
> - When `/swarm:rocky` is invoked at the top level (the typical case — user types `/swarm:rocky <task>` at the prompt), Phase 3.2.2 Native AgentTeam works as documented.
> - When `/swarm:rocky` is invoked transitively from another subagent (e.g., another skill calls `Skill("rocky")` from within an `Agent()` call), the subagent cannot spawn Claude teammates via Native AgentTeam. In that case, the skill MUST fall back to bash-spawned `claude --dangerously-skip-permissions` panes via `swarm_spawn_agent` (same wave-dispatch shape as the Codex Tier 3 path), accepting the trust-prompt and cold-start tax.
> - Detection: if you cannot find `Agent` (with `team_name` parameter) in your toolset, you are in a subagent context. Fall back to bash spawn for Claude coders.

> **CLEANUP QUIRK:** `TeamDelete` cleans up the team config and worktrees but does NOT always kill the teammate panes — `shutdown_request` → process termination is best-effort. If a teammate is idle and doesn't process the shutdown promptly, the pane may linger. Fall back to manual `tmux kill-pane -t <pane_id>` for any survivors after `TeamDelete`. Verified in eval-9b: Coder-1 needed manual kill after TeamDelete; Coder-2 and Coder-3 terminated cleanly.

## 3.3 Wave Dispatch Loop

Group tasks by wave number. Execute waves sequentially; within each wave, dispatch tasks in parallel.

```
For each wave W (1, 2, ... WAVE_COUNT):

  1. Collect all tasks assigned to wave W into an indexed array, pair each
     task to an agent pane. Maintain a task→pane map — **do not reuse a single
     `$AGENT_PANE` variable across parallel tasks** (every task would pipe to
     the same pane).

     ```bash
     # Read pane_ids back from ledger (survives across Bash invocations)
     PANES=($(grep 'pane_id:' "${SESSION_DIR}/ledger.yaml" | awk '{print $2}'))
     WAVE_TASKS=($(ls "${SESSION_DIR}/tasks/task-"*.md | grep "Wave: ${W}"))
     ```

  2. For each task in wave W, dispatch simultaneously (one task → one pane):

     ```bash
     for i in "${!WAVE_TASKS[@]}"; do
       TASK="${WAVE_TASKS[$i]}"
       PANE="${PANES[$i]}"   # task i goes to pane i
       swarm_clear_result "${TASK}"

       # Model routing (Claude agents only, when supports_model_routing: true)
       MODEL=$(swarm_classify_task "${TASK}")  # haiku | sonnet | opus

       # Pane mode (tmux/cmux) — pipe to interactive agent:
       swarm_pipe_prompt "${PANE}" "Read and implement the task at ${TASK} — write result to ${TASK%.md}.result. Use Status: DONE if complete, PARTIAL if blocked on something specific, NEEDS_HELP if uncertain, or FAILED if not viable. Correctness matters more than completion."
     done
     ```

     Headless mode (none) — one-shot exec per task:
     For Claude agents: `claude --dangerously-skip-permissions --model ${MODEL} -p "$(cat ${TASK}). Write result to ${TASK%.md}.result."`
     For Codex agents: `codex exec "$(cat ${TASK}). Write result to ${TASK%.md}.result."`
     For other agents: use `command_exec` from registry.

  3. Poll with conversation support (max 5 question turns per task):

     ```bash
     TASK_FILE="${SESSION_DIR}/tasks/task-NNN.md"
     TURN=0; MAX_TURNS=5

     while (( TURN < MAX_TURNS )); do
       EVENT=$(swarm_poll_conversation "${TASK_FILE}" 300)

       case "${EVENT}" in
         "result")
           # Agent finished — proceed to evaluation (Step 4)
           swarm_append_thread "${TASK_FILE}" "agent" "result" "$(swarm_read_result "${TASK_FILE}")"
           break
           ;;
         "question")
           # Agent needs clarification — read, answer, continue
           QUESTION=$(cat "${TASK_FILE%.md}.question")
           swarm_append_thread "${TASK_FILE}" "agent" "question" "${QUESTION}"

           # Orchestrator formulates answer using codebase knowledge
           # (Read relevant files, check context, answer concretely)
           ANSWER="[orchestrator answers based on codebase exploration]"
           swarm_post_answer "${TASK_FILE}" "${ANSWER}" "${PANES[$i]}"

           TURN=$((TURN + 1))
           ;;
         "timeout")
           # No result or question after 300s — treat as TIMEOUT in Step E
           break
           ;;
       esac
     done

     # If MAX_TURNS exhausted without .result → escalate to user
     if (( TURN >= MAX_TURNS )) && ! swarm_check_result "${TASK_FILE}"; then
       echo "Agent asked ${MAX_TURNS} questions without completing. Escalating."
       # Escalate — present thread to user for manual intervention
     fi
     ```

     The conversation thread (`.thread.jsonl`) preserves full dialogue history
     for debugging and cross-wave context sharing.

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
     | **REVISE** | STATUS=INCOMPLETE (DONE but no Files Changed) | Ask agent to re-emit result with Files Changed |
     | **PARTIAL** | STATUS=PARTIAL | Read blocker, resolve if possible (provide answer/context), then re-dispatch. If unresolvable → escalate |
     | **NEEDS_HELP** | STATUS=NEEDS_HELP | Orchestrator reads the agent's uncertainty, provides guidance via `.answer` file, re-dispatches |
     | **RETRY** | STATUS=FAILED or MALFORMED | `swarm_clear_result`, retry same task (max 2) |
     | **TIMEOUT** | STATUS=MISSING after poll timeout | Escalate to user |
     | **ESCALATE** | 3 revisions exhausted, still failing | Flag to user with diagnosis |

     Note: `swarm_check_result_status` returns DONE, PARTIAL, NEEDS_HELP, FAILED,
     INCOMPLETE, MALFORMED, or MISSING. The skill MUST handle all seven values
     (not just DONE/FAILED), otherwise PARTIAL results get misrouted as MALFORMED.

     **REVISE flow (max 3 rounds per task — per ORCHESTRATOR PUSHBACK hard rule):**
     ```bash
     # Loop until accepted or max revisions exhausted
     while swarm_can_revise "${SESSION_DIR}" "task-NNN"; do
       NEXT_REV=$(swarm_next_revision_num "${SESSION_DIR}" "task-NNN")
       REV_FILE=$(swarm_write_revision_task "${SESSION_DIR}" "task-NNN" "${NEXT_REV}" \
         "${ISSUES_DESCRIPTION}") || { echo "ERROR: revision task creation failed"; break; }
       # Dispatch revision to the SAME agent pane (with composure reset)
       swarm_pipe_prompt "${PANES[$i]}" "A previous attempt had specific issues listed below. This is normal iterative work — focus on the specific criteria that failed rather than rushing to completion. Read and address the issues in: ${REV_FILE}"
       # Poll for revision result — check exit code, timeout is not success
       if ! swarm_poll_result "${REV_FILE}" 300; then
         echo "Revision ${NEXT_REV} timed out for task-NNN. Escalating."
         break
       fi
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

  6. Between-wave: propagate discoveries to next wave

     ```bash
     DISCOVERIES=$(swarm_get_discoveries "${SESSION_DIR}")
     if [[ -n "${DISCOVERIES}" ]]; then
       # For each task in the NEXT wave, the orchestrator prepends:
       # "## Discoveries from Prior Waves\n${DISCOVERIES}"
       # when composing the dispatch prompt. This shares runtime
       # context (schema changes, API quirks, etc.) across waves.
     fi
     ```

  7. Between-wave regression check (if wave_count > 1 AND regression_gate == "baseline"):
     REGRESSED=$(swarm_check_regression "${SESSION_DIR}" "${W}")
     if [[ $? -eq 1 ]]; then
       # Regression detected — create targeted fix task
       echo "Regression detected after wave ${W}: ${REGRESSED}"
       # Correlate with files changed: git diff --stat
       # Create fix task → dispatch to agent → re-check
       # Max 1 regression-fix attempt per wave. If still regressed → escalate.
     fi
```

## 3.3.1 Conversation Termination Conditions

A task conversation terminates when ANY of these is true:

| Condition | Trigger | Action |
|-----------|---------|--------|
| Agent writes `.result` | Normal completion | Proceed to evaluation |
| Max turns reached (5) | Too many questions | Escalate to user with thread |
| Poll timeout (300s) | Agent unresponsive | Mark TIMEOUT |
| Agent writes `BLOCKED` in `.question` | Cannot proceed | Escalate to user |

The orchestrator NEVER leaves a conversation open indefinitely.

## 3.4 Claude Subagent Dispatch (fallback only)

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

## 3.5 Tier 2 — Single-coder swarm path

Reached when Phase 0.0 selected Tier 2. Skip task file creation and wave grouping (those are Tier 3). Coder identity from Phase 0.0 Decision A. Both sub-modes invoke the **Superpowers `subagent-driven-development` skill** so the SDD loop is delegated to Superpowers, not reimplemented inside swarm.

**Codex coder (default — no `--agents` flag, or `--agents codex`):**

Spawn 1 Codex pane. Codex's runtime auto-activates the Superpowers SDD skill when the prompt mentions `superpowers:subagent-driven-development` (loaded from `~/.codex/superpowers/skills/subagent-driven-development/`). Codex manages its own internal implementer / spec-reviewer / quality-reviewer loop via the skill.

```bash
PANE=$(swarm_spawn_agent "Codex-Coder" "codex" "$(pwd)" "${SESSION_DIR}" "right")
swarm_wait_agent_ready "${PANE}" 30
swarm_pipe_prompt "${PANE}" "Use superpowers:subagent-driven-development to implement the task: ${TASK_DESCRIPTION}. Acceptance criteria: ${CRITERIA}. Write result to ${SESSION_DIR}/result.md with Status: DONE/PARTIAL/NEEDS_HELP/FAILED, files changed, summary."
swarm_poll_result "${SESSION_DIR}/result.md" 600
```

**Claude coder (`--agents claude`):**

Opus invokes the Superpowers SDD skill directly in its own session — no pane, no fresh Claude process, no bash transport:

```
Skill("superpowers:subagent-driven-development")
```

The skill runs the implementer / spec-reviewer / quality-reviewer loop using in-process Claude subagents. Opus orchestrates and waits for completion.

**Cross-review (both sub-modes):**
- Plan reviewer pane (Codex) — Phase 2.5 (mandatory)
- Code reviewer — Phase 4.3a (Claude coder → Codex pane reviews via `superpowers:requesting-code-review`) or Phase 4.3b (Codex coder → Opus reviews via `Skill("superpowers:requesting-code-review")`)
- Pushback loop — up to 3 rounds per ORCHESTRATOR PUSHBACK hard rule
