# Phase 2.5: Plan Review Gate

> Loaded by `SKILL.md` Phase 2.5 pointer. Contains the full plan-review gate implementation: reviewer count selection, Codex pane spawn, consolidated findings, Opus self-evaluation pushback (HARD RULE — max 3 rounds), and reviewer cleanup.

**Skip when:** simple task (two-agent loop), `--skip-discuss` flag, or single-task plan.

> **Hard rule — planner ≠ reviewer:** Claude (Opus) wrote the plan. `--review-agents` always spawns **Codex** panes. No same-model review. If the task is simple enough to skip review, don't pass the flag.

## 2.5.1 Determine reviewer count

**Principle: N reviewers = N distinct model families.** Each reviewer should be a different model to avoid correlated conclusions. Currently 2 families available (Codex/GPT, Claude). When more are added to `agents.yaml` (e.g., DeepSeek), `--review-agents 3+` becomes meaningful.

| `--review-agents` | What spawns |
|---|---|
| `--review-agents` or `--review-agents 1` | 1 Codex pane — cross-model from Claude planner |
| `--review-agents 2` | 1 Codex standard + 1 Codex **adversarial** (same model, but adversarial framing) |
| `--review-agents N` (future) | 1 per distinct model family, then adversarial for extras |

When N > available model families: assign one reviewer per model family first, then fill extras with adversarial roles on existing models. Same-model reviewers are only useful with adversarial framing.

## 2.5.2 Spawn Codex reviewers

> **Always use `swarm_spawn_reviewer` (single) or `swarm_get_agent_field` (parallel) for command lookup.** Never hardcode `"codex"` as the command — the correct interactive command comes from `agents.yaml`. This prevents CLI flag mistakes (e.g., `--approval-policy` is MCP-only, not CLI).

**1 reviewer (default) — use the wrapper:**

```bash
swarm_spawn_reviewer "codex" "${SESSION_DIR}" \
  "${SESSION_DIR}/tasks/task-001.md" \
  "Read the task files in ${SESSION_DIR}/tasks/ and explore the codebase yourself. Assess feasibility, risks, and completeness. Form your own assessment. Write to ${SESSION_DIR}/reviews/plan-review-standard.result with Status: APPROVED or Status: NEEDS_REVISION, then your findings." \
  300 "right" "" "${SESSION_DIR}/reviews/plan-review-standard.result"
```

The wrapper handles spawn → wait → pipe → poll → kill automatically.

**2 reviewers (with adversarial) — parallel dispatch:**

```bash
AGENT_CMD=$(swarm_get_agent_field "codex" "command_interactive")
PANE1=$(swarm_spawn_agent "Codex-Reviewer" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "right")
PANE2=$(swarm_spawn_agent "Codex-Adversarial" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "down" "${PANE1}")
swarm_register_agent "${SESSION_DIR}" "Codex-Reviewer" "${PANE1}" "reviewer"
swarm_register_agent "${SESSION_DIR}" "Codex-Adversarial" "${PANE2}" "reviewer"
# Wait in parallel (background jobs + wait) — sequential is 30s × N worst case.
swarm_wait_agent_ready "${PANE1}" 30 &
swarm_wait_agent_ready "${PANE2}" 30 &
wait
swarm_pipe_prompt "${PANE1}" "Read the task files in ${SESSION_DIR}/tasks/ and explore the codebase yourself. Assess feasibility, risks, and completeness. Form your own assessment. Write to ${SESSION_DIR}/reviews/plan-review-standard.result with Status: APPROVED or Status: NEEDS_REVISION, then your findings."
swarm_pipe_prompt "${PANE2}" "Read the task files in ${SESSION_DIR}/tasks/ and explore the codebase. Your job: argue AGAINST this plan. For each task, ask: Is this necessary? Is there a simpler way? What would you cut? Write to ${SESSION_DIR}/reviews/plan-review-adversarial.result with Status: APPROVED or Status: NEEDS_REVISION, then your findings."
```

Note: prompts are intentionally **minimal framing** — "explore the codebase yourself" rather than telling the reviewer what to look for. This prevents the orchestrator from shaping conclusions.

Each reviewer writes to `${SESSION_DIR}/reviews/plan-review-{role}.result`.

Poll all results: `swarm_poll_result` per reviewer pane.

## 2.5.3 Orchestrator consolidates reviews

Opus reads ALL review results and synthesizes into a single batch table:

```markdown
## Plan Review — Consolidated Findings

Reviewers: Codex-Feasibility (APPROVED), Codex-Risk (NEEDS_REVISION)

| # | Reviewer | Task | Finding | Severity | Recommendation |
|---|----------|------|---------|----------|----------------|
| 1 | Risk | task-003 | SQL injection in query builder | Critical | Parameterize queries |
| 2 | Feasibility | task-005 | Depends on API not yet deployed | Important | Add mock/stub task |
| 3 | Risk | task-001 | No auth on admin endpoint | Important | Add auth middleware |

Accept plan as-is, or adjust tasks?
```

**Routing:**
- All APPROVED → run **2.5.3.5 Opus self-evaluation** before proceeding to Phase 3
- Any NEEDS_REVISION → present consolidated table, wait for user decision
- User approves → run **2.5.3.5 Opus self-evaluation** before proceeding
- User adjusts → update task files, re-run wave grouping if needed

## 2.5.3.5 Opus self-evaluation + pushback (HARD RULE — max 3 rounds)

Before exiting the plan-review gate, Opus performs its own evaluation of the plan AND the consolidated reviewer findings. Opus is the final arbiter — reviewer APPROVED is necessary but not sufficient.

For each task in the plan:
1. Read the task as if you're the implementer. Could you actually do it?
2. Read the acceptance criteria. Are they verifiable?
3. Read the reviewer findings. Did the reviewer miss anything obvious?
4. Mark each task: ASSURED / NOT_ASSURED (with specific concern: file:line, missing criterion, contradiction)

If ALL tasks are ASSURED → proceed to Phase 3.

If ANY task is NOT_ASSURED → push back to the plan reviewer pane with the SPECIFIC concern and increment the round counter. **Use a unique result filename per round** so the audit trail is preserved (do not overwrite a single file across rounds):

```bash
# Pushback round R/3 — write result to plan-review-rR.result (not plan-review-standard.result)
swarm_pipe_prompt "${PANE1}" "Round ${R}/3 — pushback: I am not assured about task-NNN. Specific concern: [exact issue, e.g., 'acceptance criterion idempotent migration is not addressed in the proposed steps; the migration as written would double-apply if re-run']. Re-read task-NNN, address this specific concern, and update your review at ${SESSION_DIR}/reviews/plan-review-r${R}.result with revised findings."
swarm_poll_result "${SESSION_DIR}/reviews/plan-review-r${R}.result" 300
# Re-run 2.5.3 consolidation reading the latest rN file, then re-run 2.5.3.5 self-eval
```

After **3 rounds total**, escalate to user with diagnosis:
> "Plan reviewer cannot fully address my concerns after 3 pushback rounds. Remaining NOT_ASSURED items: [list]. Proceed anyway, revise the plan manually, or abort?"

Pushback rounds count against the same 3-round budget that applies to Phase 3.3 (REVISE flow) and Phase 4.4 (fix loop). They are separate per-gate counters but bound by the same hard rule.

> **VERIFIED in eval-10 (iter-2):** Codex's responsiveness to pushback prompts is excellent — when given a concrete concern in the format above, Codex addresses it directly in the next turn AND retains context from prior rounds (round 3 visibly built on rounds 1 and 2 in the test). The mechanism is implementable end-to-end on top of the swarm bash transport. Per-round result filenames (plan-review-r0/r1/r2/r3.result) preserve the audit trail; overwriting a single plan-review-standard.result loses prior rounds.

> **macOS portability note:** The `timeout` command is not on macOS by default. Use `swarm_poll_result` (which has its own timeout) or a manual polling loop:
> ```bash
> for ((i=0; i<150; i++)); do [[ -s "$file" ]] && break; sleep 2; done
> ```
> Do not use `timeout 300 cmd ...` in skill bash blocks — it will fail with `command not found` on macOS without `gtimeout` from coreutils.

## 2.5.4 Cleanup reviewer panes

```bash
# Kill all reviewer panes — plan review is a gate, not persistent
for PANE in ${REVIEW_PANES[@]}; do
  swarm_kill_agent "${PANE}"
done
```
