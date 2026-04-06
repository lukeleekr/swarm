# Phase 4: Review

> Loaded by `SKILL.md` Phase 4 pointer. Contains the cross-model code review gate: reviewer determination, pre-flight validation, review context preparation, Codex review via Superpowers skill (4.3a), Claude two-stage review (4.3b), and the fix loop with pushback.

**Cross-review rule:** The reviewer must be a different agent than the coder.

| Coder Agent | Reviewer | How |
|-------------|----------|-----|
| Claude (any model) | Codex | `codex review` or `codex exec` with review prompt |
| Codex | Claude Opus (orchestrator) | Invoke `Skill("superpowers:requesting-code-review")` → spawns `superpowers:code-reviewer` subagent |

After all tasks complete:

## 4.1 Determine reviewer (with pre-flight validation)

Read the `--agents` flag used in this session. Select reviewer per the table above.

**Pre-flight check (mandatory):** Before dispatching any review, validate that the selected coder and reviewer are not the same agent type. Specifically:
- If `--agents codex,codex` or any configuration where all coders and the reviewer resolve to the same agent type → **WARN the user**: "Cross-review violation: coder and reviewer are the same agent ([agent]). Reviews by the same agent that wrote the code provide weaker guarantees. Override? [Y/n]"
- If user declines override → fall back to Claude Opus orchestrator as reviewer (always available).
- Two Claude variants (e.g., Claude Sonnet coding, Claude Opus reviewing) are acceptable — the cross-review rule applies to the agent *identity*, not the model.

## 4.2 Prepare review context

```bash
# PRE_SWARM_SHA was captured at Phase 0.5 init:
#   PRE_SWARM_SHA=$(git rev-parse HEAD)
# If not set, fall back to HEAD~1
BASE_SHA="${PRE_SWARM_SHA:-$(git rev-parse HEAD~1)}"
HEAD_SHA=$(git rev-parse HEAD)
```

Aggregate from all `.result` files: files changed, summaries, what was implemented.

## 4.3a Codex reviews (when coder was Claude) — invokes Superpowers skill

Spawn a Codex pane and invoke the **Superpowers `requesting-code-review` skill** from `~/.codex/superpowers/skills/requesting-code-review/`. This is symmetric to Phase 4.3b which invokes `Skill("superpowers:requesting-code-review")` on the Claude side. Same Superpowers skill, both sides.

```bash
PANE=$(swarm_spawn_agent "Codex-Reviewer" "codex" "$(pwd)" "${SESSION_DIR}" "right")
swarm_wait_agent_ready "${PANE}" 30
swarm_pipe_prompt "${PANE}" "Use superpowers:requesting-code-review to review the code changes between ${BASE_SHA}..${HEAD_SHA}. Focus on: correctness, edge cases, security, test coverage, cross-component consistency. Write findings to ${SESSION_DIR}/reviews/review-final.result with format: Status: APPROVED or Status: NEEDS_REVISION, then Strengths, Issues (Critical/Important/Minor), Assessment."
swarm_poll_result "${SESSION_DIR}/reviews/review-final.result" 600
swarm_kill_agent "${PANE}"
```

Codex auto-activates the skill when its name appears in the prompt — Codex's runtime detects `superpowers:requesting-code-review` and loads `~/.codex/superpowers/skills/requesting-code-review/SKILL.md`.

**Do NOT** use `codex exec` with a hand-crafted review prompt. **Do NOT** use the local `/code-review` skill or `codex review` subcommand — those are different from the Superpowers `requesting-code-review` skill (verified by spawning a Codex pane and checking the filesystem).

## 4.3b Claude Opus reviews (when coder was Codex) — Two-Stage SDD Review

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

## 4.4 Fix loop

Act on reviewer feedback:
- **Critical** → create fix tasks, dispatch to coder agents, re-review (max 3 rounds)
- **Important** → create fix tasks, dispatch (same loop)
- **Minor** → note in report, do not block

If still failing after 3 rounds → escalate to user.

```bash
swarm_set_progress "Reviewing" "0.75"
```
