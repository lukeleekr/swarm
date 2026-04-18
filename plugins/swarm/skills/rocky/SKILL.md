---
name: rocky
description: "Manager-orchestrated multi-agent swarm with Tier 0-3 smart routing. Auto-downgrades from parallel wave dispatch to Opus inline, so invoke whenever orchestration MIGHT help. Triggers: swarm, multi-agent, parallel, codex agents, spawn agents, cross-model review, rocky, orchestrate, team, wave dispatch, codex SDD."
argument-hint: "<task> [--keep-panes] [--agents <name>] [--review-agents [N]] [--dry-run] [--sequential] [--resume] [--skip-discuss]"
---

# /swarm:rocky — Multi-Agent Orchestration

> **allowed-tools**: `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Agent`, `TaskCreate`, `TaskUpdate`, `TaskList`, `Skill`, `AskUserQuestion`, `TeamCreate`, `TeamDelete`, `SendMessage`

> **HARD RULE — NO MCP FOR DISPATCH**: ALL agent interaction via transport lib (`swarm_spawn_agent`, `swarm_pipe_prompt`, `swarm_poll_result`). NEVER `mcp__codex__codex`. Bypassing pane orchestration is a protocol violation. **For reviewers**: use `swarm_spawn_reviewer` (single, blocking) or `swarm_get_agent_field` + manual dispatch (parallel). Never hardcode `"codex"` as a spawn command — always look up `command_interactive` from `agents.yaml`.

> **HARD RULE — CROSS-MODEL REVIEW**: Reviewer MUST differ from author's model family. Claude→Codex reviews. Codex→Claude reviews. Exception: Tier 0/1 (trivial). Plan reviewer: always Codex pane. Code reviewer: opposite-model (Codex coder→Claude 4.3b, Claude coder→Codex 4.3a).

> **HARD RULE — PUSHBACK (MAX 3 ROUNDS)**: Opus pushes back with SPECIFIC concerns (file:line, missing AC, contradictory reasoning). 3 rounds per gate max, then escalate to user. Applies at Phase 2.5, 3.3 REVISE, 4.4 fix loop. This is the primary quality mechanism.

## Transport Library API

**Use `swarm_spawn_reviewer` (high-level) for review/consultation tasks — NOT `swarm_spawn_agent` (low-level).**

| Function | Use when | Handles |
|----------|----------|---------|
| `swarm_spawn_reviewer` | Review, consultation, any blocking pane task | Lookup + spawn + wait + prompt + poll + cleanup |
| `swarm_spawn_agent` | Building block for custom dispatch | Raw tmux split-window only (manual command lookup required) |

```bash
# CORRECT: Use high-level wrapper
swarm_spawn_reviewer "codex" "${SESSION_DIR}" "${TASK_FILE}" \
  "@${TASK_FILE}" 180 "right" "" "${TASK_FILE%.md}.result"

# WRONG: Low-level requires manual lookup + proper args
CMD=$(swarm_get_agent_field "codex" "command_interactive")
swarm_spawn_agent "codex" "$CMD" "$WORKDIR" "$SESSION_DIR"
```

Failure mode: calling `swarm_spawn_agent` without proper args → broken `/logs/` path, silent failure.

<!-- Phase Flow:
  0.0: SMART ROUTER → Tier 0/1 (skip) or 2/3 (continue)
  0: Init (mux, interrupted/stale, registry, session)
  0.6: Memory retrieval preflight
  1: Context detection + routing
  1.5: Grey area batch table
  2: Plan decomposition + wave grouping
  2.5: Plan review gate
  3: Wave dispatch + regression checks
  4: Cross-model code review + fix loop
  5: Verification routing (flaky pre-filter → passed/gaps_found/human_needed)
  6: Report, cleanup, next steps
-->

## Purpose

Manager-orchestrated swarm: Claude dispatches work to Codex CLI (and future agents) via file-based messaging. Integrates with superpowers specs/plans.

## Decomposition Doctrine

> Multi-agent systems fail less from weak models than from badly specified task boundaries.

Orchestrator's primary value = **decomposition quality**, not routing sophistication. Each task is an **API contract**, not a vague work request. **Litmus test:** Could a competent new hire complete this with only this prompt, repo access, and no follow-up chat?

**Well-decomposed = self-contained + verifiable + cheap to retry.** Don't split below the semantic unit — too-tiny tasks create coordination overhead. Right size: independent enough to parallelize, coherent enough to not need reintegration glue. See Quality Gate (Phase 2) for operational checklist.

## Argument Parsing

`--keep-panes` keep panes | `--agents <names>` coder identity | `--dry-run` plan only | `--sequential` disable parallelism | `--resume` resume interrupted session | `--skip-discuss` skip 1.5+2.5 | `--review-agents [N]` plan reviewer panes (1/model family, extras get adversarial role) | everything else → task description

## Phase 0.0: Smart Router (BEFORE transport library)

Walk top-down, pick FIRST tier that fits, BEFORE sourcing the transport library or initializing any session state. Skips Phases 0.1–6 for Tier 0/1.

### Tier table

| Tier | Mechanism | Plan reviewer | Coder | Code reviewer |
|---|---|---|---|---|
| **0** | Opus inline | — | Opus | — |
| **1** | `Agent()` in-process | — | Claude subagent | — |
| **2** | SDD (sequential + review gates) | Codex pane | Codex (default) or Claude (`--agents claude`) | Opposite-model |
| **3** | Parallel multi-coder | Codex pane | Codex panes (default) or Claude teammates (`--agents claude`) | Opposite-model |

### Tier signals

**Tier 0:** ≤20 LOC, 1 file, mechanical, Opus has file in context (or <200 lines to read), no design judgment. → Opus directly. No `.swarm/`, no cross-model.

**Tier 1:** 1–3 files, mechanical, no ACs, one-shot. → `Agent(subagent_type=<focused>, prompt=...)` no `team_name`. Types: test-specialist, Explore, Plan, backend/frontend/database/security-specialist, general-purpose. No cross-model.

**Tier 2:** Substantive feature/fix with ACs, ordered dependencies. → Phase 0.1+, single-coder path (Phase 3.5). Reviews mandatory.

**Tier 3:** 3+ truly independent tasks (disjoint files), OR user wants multi-pane. → Phase 0.1+, wave dispatch (Phase 3.3). Reviews mandatory.

### Dispatch mechanism (Tier 2/3)

Coder: `--agents claude` → Claude; default → Codex.

| Tier | Codex (default) | Claude (`--agents claude`) |
|---|---|---|
| 2 | 1 pane via `swarm_spawn_agent`, runs `superpowers:subagent-driven-development` internally | Opus invokes `Skill("superpowers:subagent-driven-development")` in-process |
| 3 | Multiple panes via `swarm_spawn_agent` (wave dispatch) | `TeamCreate` + `Agent(team_name=..., name=...)` — Native AgentTeam. See `references/phase-3-dispatch.md` |

### Tie-breakers

Two tiers fit → LOWER. User says "team"/"agents"/"watch" → Tier 3. Ambiguous → Tier 1 + Explore, re-tier. `--agents` overrides coder identity, not tier.

### Announcement

One line: `"Tier {N}, {mechanism}. {reviewers if Tier 2+}."`
E.g.: "Tier 2, Codex SDD (single pane), Codex plan reviewer, Claude code reviewer."

## Phase 0: Prerequisites & Init

### 0.1 Source Transport Library
```bash
source ~/.claude/local-plugins/plugins/swarm/lib/swarm-transport.sh
```

### 0.2 Detect Multiplexer
```bash
MUX=$(swarm_detect_mux)  # cmux → full panes+sidebar | tmux → panes | none → background
```

### 0.3 Interrupted / Stale Sessions
```bash
INTERRUPTED=$(swarm_find_interrupted_sessions "$(pwd)")
STALE=$(swarm_find_stale_sessions "$(pwd)")
```
- `--resume` + interrupted → offer resume from last wave (reuse `SESSION_DIR`, `swarm_update_ledger_field "${SESSION_DIR}" "resumed_from" "${INTERRUPTED_SESSION_ID}"`). Decline → fresh.
- `--resume` + nothing → warn, start fresh.
- No flag + interrupted → ask resume or fresh.
- Stale → offer `swarm_cleanup`.

### 0.4 Read Agent Registry
Read `~/.claude/local-plugins/plugins/swarm/agents.yaml`. Verify at least one agent on PATH.

### 0.5 Initialize Session (Tier 2/3 only)

**Pre-flight: PWD must be a git repo** — Phase 4 needs `PRE_SWARM_SHA..HEAD` diff baseline.

```bash
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "ERROR: /swarm:rocky requires a git repo. cd to target repo first." >&2; exit 1; }
PRE_SWARM_SHA=$(git rev-parse HEAD)
SESSION_ID=$(swarm_new_session "$(pwd)")
SESSION_DIR="$(pwd)/.swarm/${SESSION_ID}"
swarm_init_ledger "${SESSION_DIR}" "${SESSION_ID}" "${MUX}"
swarm_ensure_gitignore "$(pwd)"
swarm_validate_cache_sync "swarm" >&2 || echo "WARNING: source/cache diverged. Run swarm_sync_plugin_cache." >&2
swarm_set_status "Swarm Leader"
swarm_set_progress "Init" "0.05"
```

## Phase 0.6: Memory Retrieval Preflight (Tier 2/3 only)

Lexical retrieval over Luke's memory corpora:
- **Pass 1 lexical:** `.md` files in `~/.claude/memory` + `~/.claude/projects/-Users-lukelee/memory` (excluding log/lint/MEMORY.md). Scores via frontmatter `name:`/`description:` + filename tokens.

```bash
swarm_memory_preflight "${SESSION_DIR}" "${ARGUMENTS}"
swarm_set_progress "Memory Preflight" "0.07"
```

If `swarm_memory_preflight` exits non-zero, stop and surface the error — later phases require `${SESSION_DIR}/memory-hits.md`.

## Phase 1: Context Detection

### 1.1 Check for Superpowers Artifacts
Search: `docs/superpowers/specs/*-design.md` (specs), `docs/superpowers/plans/*-plan.md` or `.plans/*.md` (plans).

### 1.1.1 Parallel Context Gathering (complex tasks)
Up to 3 parallel Explore subagents before brainstorming. Skip for simple tasks.
```
Agent(subagent_type="Explore", name="arch-scan", prompt="Scan codebase architecture: directory structure, key modules, tech stack, entry points")
Agent(subagent_type="Explore", name="pattern-scan", prompt="Find similar patterns for [task]: analogous implementations, conventions, reusable utilities")
Agent(subagent_type="Explore", name="test-scan", prompt="Identify test patterns: framework, fixtures, coverage areas, how to verify [task]")
```

### 1.2 Route

| Found | Action |
|-------|--------|
| Spec + plan | Read plan → Phase 2 |
| Spec only | `Skill("superpowers:writing-plans")` → Phase 2 |
| Nothing + complex | 1.1.1 → `Skill("superpowers:brainstorming")` → writing-plans → Phase 2 |
| Nothing + simple | Skip to Phase 3 |

### 1.3 State classification to user
State Tier 2 vs Tier 3 sub-classification to the user and let them override. Phase 0.0's tier is binding; this picks the internal Phase 3 path (3.5 single-coder vs 3.3 wave dispatch).

## Phase 1.5: Grey Area Discussion

**Skip when:** simple task, `--skip-discuss`, or no ambiguous decisions.

Scan plan for ambiguous decisions. Present 3–5 as batch table with recommendations:

```markdown
| # | Grey Area | Recommendation | Alternative |
|---|-----------|---------------|-------------|
| 1 | Auth approach | JWT tokens | Session cookies |
```

User accepts all or overrides. Embed resolved decisions into Phase 2 task files' `## Decisions` section.

## Phase 2: Plan Decomposition

Read plan + `${SESSION_DIR}/memory-hits.md`. For each work unit, write `${SESSION_DIR}/tasks/task-NNN.md`:

```markdown
# Task NNN: [title]
## Context
Project: [pwd] | Branch: [branch] | Session: [id] | Wave: [post-grouping]
## Depends On
[task-NNN or empty]
## Files to Touch
[file list]
## Decisions
[resolved grey areas from Phase 1.5]
## Assignment
[what to implement]
## Acceptance Criteria
[what "done" means]
## Instructions
Write result to: [task-NNN.result]
Format: Status (DONE|PARTIAL|NEEDS_HELP|FAILED), Files Changed, Summary, Issues, Confidence (HIGH/MEDIUM/LOW).
- DONE=all ACs met. PARTIAL=hit specific blocker (describe it). NEEDS_HELP=uncertain (describe attempts). FAILED=cannot proceed (explain why).
- **Correctness over completion.** Honest incompleteness > forced solution.
- **Questions:** write to task-NNN.question, WAIT for task-NNN.answer (max 5/task).
```

### Decomposition Quality Gate

Before wave grouping, verify each task file against the doctrine:

| Check | Pass condition |
|-------|---------------|
| Self-contained | Agent can start without asking other agents for decisions |
| Specific verbs | Assignment uses `add`, `rename`, `extract`, `replace` — not `improve`, `clean up` |
| Bounded scope | Files to Touch is explicit; no open-ended "find and fix" |
| Falsifiable ACs | Each AC is mechanically checkable (test, grep, file exists) |
| Right granularity | One semantic unit — not bundled exploration+design+impl+QA |
| No hidden deps | If task B needs task A's output, B is in a later wave |

If a task fails any check, **rewrite the task** — don't dispatch and hope. Bad decomposition is the #1 cause of swarm failure, not weak models.

Wave grouping:
```bash
WAVE_RESULT=$(swarm_group_waves "${SESSION_DIR}")  # exit 0=success, 2=cycle→present to user, stop
swarm_update_ledger_field "${SESSION_DIR}" "tasks_total" "N"
swarm_update_ledger_field "${SESSION_DIR}" "wave_count" "W"
```
`--sequential` → wave N = task N. `--dry-run` → present plan + stop.

```bash
swarm_set_progress "Planning" "0.15"
```

## Phase 2.5 — Plan Review Gate

**Skip when:** simple task, `--skip-discuss`, or single-task plan.

Spawns Codex plan reviewer pane(s), polls results, consolidates findings, runs Opus pushback (max 3 rounds per hard rule), kills reviewer panes.

**See:** `references/phase-2-5-plan-review.md` for 2.5.1–2.5.4 (spawn, findings table, pushback template, cleanup).

## Phase 3 — Execute

Wave dispatch: regression baseline, agent spawn (Codex panes or Claude AgentTeam), conversation polling (max 5 questions/task), REVISE flow (max 3 rounds), between-wave regression checks. Phase 3.5 = Tier 2 single-coder path.

**See:** `references/phase-3-dispatch.md` for 3.1–3.5 (baseline, spawn, wave loop, REVISE, termination, fallback, Tier 2 path).

## Phase 4 — Review

Cross-model code review: determine reviewer (opposite family), prepare context (`PRE_SWARM_SHA..HEAD` diff + results). 4.3a: Codex pane runs `superpowers:requesting-code-review`. 4.3b: Opus runs it in-process (two-stage: spec → quality). Fix loop: up to 3 rounds for Critical/Important.

**See:** `references/phase-4-review.md` for 4.1–4.4.

## Phase 5 — Verification Routing

Automated checks (pytest, git diff/status) → flaky pre-filter (rerun 2×, classify deterministic/flaky/infra) → state classification (passed/gaps_found/human_needed). Gap closure: max 1 round, regression-gated, targeted fix tasks.

**See:** `references/phase-5-verification.md` for 5.1–5.5.

## Phase 6 — Done & Error Handling

Generate `${SESSION_DIR}/report.md`, cleanup panes (unless `--keep-panes`), present report. Next steps: commit, `superpowers:verification-before-completion`, `superpowers:finishing-a-development-branch`.

**See:** `references/phase-6-and-errors.md` for report template + error handling (16 scenarios).
