---
name: rocky
description: "Manager-orchestrated multi-agent swarm with smart routing. Use whenever the user wants to spawn multiple coding agents in parallel, coordinate Codex and Claude on the same project, get cross-model code review (Claude codes → Codex reviews, or vice versa), implement multiple features simultaneously in parallel waves, watch agents work visually in tmux panes, run a Tier 2 SDD pipeline (single coder with plan + code review gates), or orchestrate any task too large for a single agent. Trigger phrases include: 'swarm', 'multi-agent', 'parallel coders', 'codex agents', 'spawn N agents', 'have N agents work on', 'watch the agents', 'cross-model review', 'rocky', 'orchestrate this', 'team of coders', 'work in parallel', 'use a swarm', 'use a team', 'wave dispatch', 'codex SDD', 'native agent team'. The skill includes a Phase 0.0 smart router that automatically picks the lightest mechanism (Opus inline / single subagent / single SDD pane / parallel multi-coder waves) — so it is safe to invoke whenever orchestration MIGHT be useful, even if the task seems small. The router downgrades automatically rather than over-engineering, so under-triggering is the bigger risk. Make sure to use this skill for any complex multi-step coding work, anytime the user mentions agents/coders/orchestration/swarms/teams, or anytime cross-model review would add value (which is most non-trivial features)."
argument-hint: "<task> [--keep-panes] [--agents <name>] [--review-agents [N]] [--dry-run] [--sequential] [--resume] [--skip-discuss]"
---

# /swarm:rocky — Multi-Agent Orchestration

> **allowed-tools**: `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Agent`, `TaskCreate`, `TaskUpdate`, `TaskList`, `Skill`, `AskUserQuestion`, `TeamCreate`, `TeamDelete`, `SendMessage`

> **HARD RULE — NO MCP TOOLS FOR AGENT DISPATCH**: NEVER use `mcp__codex__codex` or any MCP server tool to dispatch work to agents. ALL agent interaction MUST go through the transport lib: `swarm_spawn_agent` (spawn in pane), `swarm_pipe_prompt` (send work), `swarm_poll_result` (get results). Using MCP tools bypasses the visual pane orchestration and is a protocol violation.

> **HARD RULE — CROSS-MODEL REVIEW**: The reviewer MUST be a different model family than the author. Claude plans → **Codex reviews** the plan (`--review-agents`). Claude codes → **Codex reviews** the code. Codex codes → **Claude Opus reviews** the code. Same-model review is not independent review. Exception: trivial/simple tasks (Tier 0/1 in Phase 0.0) where the orchestrator handles both inline without a formal review phase.

> **HARD RULE — ORCHESTRATOR PUSHBACK (MAX 3 ROUNDS)**: Opus is the final arbiter at every gate. If not fully assured of plan quality, code correctness, or review thoroughness, Opus pushes back to the producer with a SPECIFIC concern (file:line, missing acceptance criterion, contradictory reasoning). The producer addresses the concern. Opus re-evaluates. Up to **3 rounds per gate** before escalating to the user. Applies to plan review (Phase 2.5), implementation (Phase 3.3 REVISE flow), and code review (Phase 4.4 fix loop). Pushback rounds are not optional fallback — they are the orchestrator's primary quality mechanism.

<!-- Phase Flow (V2 complete):
  Phase 0.0: SMART ROUTER — picks Tier 0/1 (skip swarm) or Tier 2/3 (continue)
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
- `--skip-discuss` → skip Phase 1.5 grey area extraction and Phase 2.5 plan review
- `--review-agents` or `--review-agents N` → N plan reviewer panes (1 per model family, extras get adversarial role)
- Everything else → task description

## Phase 0.0: Smart Router (RUNS FIRST — before sourcing the transport library)

> **/swarm:rocky is a smart router. It absorbs Native AgentTeam, Superpowers SDD,
> and full swarm orchestration behind one entry point. It must never be worse
> than picking the right tool by hand. Phase 0.0 picks the lightest mechanism
> that satisfies the cross-model rule and the user's intent.**

Walk this rubric BEFORE sourcing the transport library or initializing any
session state. Phase 0.0 may decide that swarm machinery is unnecessary —
in which case Phases 0.1–6 are skipped entirely.

### Tier table

| Tier | Mechanism | Plan author | Plan reviewer | Coder | Code reviewer |
|---|---|---|---|---|---|
| **0** | Opus inline (no dispatch) | — | — | Opus | — |
| **1** | Plain `Agent()` in-process (Claude subagent) | — | — | Claude subagent | — |
| **2** | SDD (sequential, with internal review gates) | Opus | **Codex pane** | **Codex** (default) or Claude (`--agents claude`) | Opposite-model |
| **3** | Parallel multi-coder | Opus | **Codex pane** | **Codex** panes (default) or Claude teammates (`--agents claude`) | Opposite-model |

### Tier signals — walk top-down, pick FIRST tier that fits, STOP

**Tier 0 — Opus inline:** ≤20 LOC, 1 file, mechanical, Opus already has the file in context (or it's <200 lines to read), no design judgment required.
→ Action: Opus does the work directly. Do NOT source the transport library. Do NOT create a `.swarm/` session. Cross-model rule does not apply (existing exception for trivial work).

**Tier 1 — Plain `Agent()` in-process:** 1–3 files, mechanical, no formal acceptance criteria, one-shot dispatch is sufficient.
→ Action: Dispatch via plain `Agent(subagent_type=<focused>, prompt=...)` with **no `team_name`**. Pick the focused subagent type (test-specialist, Explore, Plan, backend-specialist, frontend-specialist, database-specialist, security-specialist, or general-purpose). Single in-process call, no tmux pane, no fresh Claude process. Cross-model rule does not apply (existing exception for mechanical work).

**Tier 2 — SDD (sequential with quality gates):** Substantive feature/fix with acceptance criteria, ordered dependencies, quality matters more than throughput.
→ Action: Continue to Phase 0.1 (init). Inside Phase 3, take the **single-coder path (Phase 3.5)**. Plan reviewer (Codex pane) and code reviewer (cross-model) are mandatory. Pushback hard rule applies.

**Tier 3 — Parallel multi-coder:** 3+ tasks that are TRULY independent (disjoint files/modules), throughput from parallelism wins more than serialization safety, OR user explicitly wants visible multi-pane orchestration, OR cross-model orchestration is the point.
→ Action: Continue to Phase 0.1 (init). Inside Phase 3, take the **wave dispatch path (Phase 3.3)**. Coder identity from Decision A; transport from Decision B. Plan reviewer + code reviewer mandatory. Pushback hard rule applies.

### Decision A — Coder identity (Tier 2/3 only)

```
--agents claude  → Claude
--agents codex   → Codex
default          → Codex
```

### Decision B — Sub-mode dispatch (Tier 2/3, after Decision A)

| Tier | Coder | Mechanism |
|---|---|---|
| 2 | Codex (default) | 1 Codex pane via `swarm_spawn_agent`. Prompt uses `superpowers:subagent-driven-development` to invoke the Superpowers SDD skill from `~/.codex/superpowers/skills/subagent-driven-development/`. Codex runs the SDD loop internally. |
| 2 | Claude (`--agents claude`) | Opus invokes `Skill("superpowers:subagent-driven-development")` directly in its own session. No pane. Same Superpowers skill, Claude side. |
| 3 | Codex (default) | Multiple Codex panes via `swarm_spawn_agent` in wave layout (existing Phase 3.3 wave dispatch). Bash transport. |
| 3 | Claude (`--agents claude`) | `TeamCreate` + multiple `Agent(subagent_type=..., team_name=..., name=..., prompt=...)` calls — **Native AgentTeam**. Each teammate is a Claude in a tmux pane. NOT bash-spawned `claude --dangerously-skip-permissions`. See `references/phase-3-dispatch.md`. |

### Cross-model rule recap (Tier 2 and 3)

- **Plan reviewer**: Codex pane, always. Phase 2.5.2 spawns it.
- **Code reviewer**: opposite-model.
  - Codex coder → Claude reviews via `Skill("superpowers:requesting-code-review")` in Opus's session — Phase 4.3b.
  - Claude coder → Codex reviews via Codex pane prompt using `superpowers:requesting-code-review` — Phase 4.3a.

### Tie-breakers

- Two tiers fit → pick the LOWER one (lightest path that fits).
- User says "use a team" / "spawn agents" / "I want to watch it" → bump to Tier 3.
- Task is ambiguous → Tier 1 with `Plan` or `Explore` first to scope, then re-tier.
- `--agents` flag overrides default coder identity but not the tier (tier is still picked by signals).

### Phase 0.0 announcement

State to the user (one line) before continuing:
> "Tier {N}, {coder} {mechanism}. {Plan reviewer + code reviewer if Tier 2+}."

Examples:
- "Tier 0, Opus inline. No dispatch."
- "Tier 1, Claude subagent (general-purpose). No review needed."
- "Tier 2, Codex SDD (single pane), Codex plan reviewer, Claude code reviewer."
- "Tier 3, Claude Parallel via Native AgentTeam (4 teammates), Codex plan reviewer, Codex code reviewer."

Then proceed to Phase 0.1 (Tier 2/3) or stop (Tier 0/1).

## Phase 0: Prerequisites & Init

### 0.1 Source Transport Library

```bash
source ~/.claude/local-plugins/plugins/swarm/lib/swarm-transport.sh
```

### 0.2 Detect Multiplexer

```bash
MUX=$(swarm_detect_mux)
```

Report to user: `cmux` → "Running in CMUX — full visual panes + sidebar status"; `tmux` → "Running in tmux — visual panes enabled"; `none` → "No multiplexer detected — agents will run as background processes".

### 0.3 Check for Interrupted / Stale Sessions

```bash
INTERRUPTED=$(swarm_find_interrupted_sessions "$(pwd)")
STALE=$(swarm_find_stale_sessions "$(pwd)")
```

- **`--resume` AND interrupted session found:** read its ledger + completed task results, present "Found interrupted session [ID]. N of M tasks complete. Resume from wave W?". On approval: reuse `SESSION_DIR`, record `swarm_update_ledger_field "${SESSION_DIR}" "resumed_from" "${INTERRUPTED_SESSION_ID}"`, skip to Phase 3 with only remaining tasks. On decline: fresh session.
- **`--resume` but no interrupted session:** warn "No interrupted sessions found. Starting fresh."
- **No `--resume` but interrupted session exists:** ask "Found interrupted session [ID]. Resume it, or start fresh?"
- **Stale sessions found (no progress):** ask "Found N stale swarm sessions. Clean up orphan panes? [Y/n]". If yes, call `swarm_cleanup` on each stale session directory.

### 0.4 Read Agent Registry

Read `~/.claude/local-plugins/plugins/swarm/agents.yaml`. Verify that at least one agent's command is available on PATH (e.g., `which codex`). Warn if missing.

### 0.5 Initialize Session

> **Reached only if Phase 0.0 selected Tier 2 or 3.** Tiers 0/1 never run this — they have no `.swarm/` session, no ledger, no PRE_SWARM_SHA.

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

Search for: (1) `docs/superpowers/specs/*-design.md` — recent design specs; (2) `docs/superpowers/plans/*-plan.md` OR `.plans/*.md` — implementation plans.

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

### 1.3 Tier-2 vs Tier-3 sub-classification

You are here because Phase 0.0 selected Tier 2 or Tier 3. Now classify which path to take inside Phase 3:

**Tier 2 — single-coder swarm path (Phase 3.5):** 1 substantive task (or task set with strict ordering). Sequential SDD pattern is the right shape. Dispatched to one coder agent (Codex pane by default — runs SDD internally; or Claude via in-process Skill invocation when `--agents claude`).

**Tier 3 — multi-coder wave dispatch (Phase 3.3):** Multiple tasks groupable into parallel waves with disjoint scopes. Dispatched to multiple coder agents simultaneously (Codex panes by default via `swarm_spawn_agent`; Claude teammates via Native AgentTeam when `--agents claude` — see `references/phase-3-dispatch.md`).

State your classification to the user and let them override. Phase 0.0's tier choice is binding; this section only picks the *internal* path within the selected tier.

## Phase 1.5: Pre-Execution Discuss (Grey Areas)

**Skip this phase when:** simple task (two-agent loop), `--skip-discuss` flag, or manager judges the plan has no ambiguous decisions.

After reading the plan (Phase 1.1) and before writing task files (Phase 2):

### 1.5.1 Scan for grey areas

Read the plan and identify decisions that are ambiguous or could go multiple ways: technology choices ("use X or Y?"), data format decisions ("JSON vs YAML?", "REST vs GraphQL?"), scope boundaries ("include error handling for X?"), architecture decisions ("single file vs split?"), naming conventions unclear from spec.

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

User responds: accept all (fast path) or override specific items. Store resolved decisions for embedding into task files in Phase 2. Each task file will include a `## Decisions` section with grey areas relevant to that task.

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
   - Status: DONE | PARTIAL | NEEDS_HELP | FAILED
   - Files Changed: [list]
   - Summary: [what you did]
   - Issues: [any problems encountered]
   - Confidence: [HIGH/MEDIUM/LOW — how confident you are in the solution]

   Status guide:
   - DONE: completed all acceptance criteria
   - PARTIAL: made meaningful progress but hit a specific blocker (describe it)
   - NEEDS_HELP: uncertain about approach — describe what you tried and what's unclear
   - FAILED: attempted and cannot proceed (explain why)

   **Correctness over completion.** Honest incompleteness is better than a forced
   solution that technically passes but violates intent. If constraints seem impossible
   or mis-specified, explain the mismatch rather than gaming around it.

   **Conversation protocol — if you need clarification:**
   Write your question to: [path to task-NNN.question]
   Then WAIT — do not proceed until [path to task-NNN.answer] appears.
   Read the answer, then continue your work.
   You may ask up to 5 questions per task.
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

## Phase 2.5 — Plan Review Gate

**Skip when:** simple task (two-agent loop), `--skip-discuss` flag, or single-task plan.

> Spawns Codex plan reviewer pane(s) (1 by default; `--review-agents N` for N reviewers, with adversarial framing for extras), polls results, consolidates into a batch table, runs **2.5.3.5 Opus self-evaluation + pushback** (HARD RULE — max 3 rounds: Opus reads each task as if implementer, marks ASSURED/NOT_ASSURED, pushes back to reviewer pane with specific concern, escalates to user after 3 rounds), then kills reviewer panes.

**See:** `references/phase-2-5-plan-review.md` for the full 2.5.1–2.5.4 implementation, including the spawn commands, the consolidated findings table format, the pushback prompt template, and the cleanup loop.

```bash
swarm_set_progress "Plan Reviewed" "0.20"
```

## Phase 3 — Execute

> Wave dispatch loop. Captures regression baseline (when `wave_count > 1`), reads `agents.yaml`, picks dispatch method per task (pane vs SDD subagent), spawns Codex panes via `swarm_spawn_agent` OR Claude teammates via Native AgentTeam (`TeamCreate` + `Agent(team_name=...)` for Tier 3 `--agents claude`), runs the conversation polling loop (max 5 question turns per task), evaluates results with the self-corrective REVISE flow (max 3 rounds per ORCHESTRATOR PUSHBACK hard rule), and runs between-wave regression checks. Phase 3.5 is the Tier 2 single-coder path (Codex SDD pane OR in-process `Skill("superpowers:subagent-driven-development")` for Claude).

**See:** `references/phase-3-dispatch.md` for sections 3.1 (regression baseline), 3.2 (spawn agents + grid layout), 3.2.1 (dispatch method selection), 3.2.2 (Tier 3 Claude Parallel via Native AgentTeam), 3.3 (wave dispatch loop with REVISE flow), 3.3.1 (conversation termination), 3.4 (Claude subagent fallback), 3.5 (Tier 2 single-coder swarm path).

## Phase 4 — Review

> Cross-model code review gate. Determines reviewer per the cross-review rule (Codex coder → Claude Opus reviewer; Claude coder → Codex reviewer), runs pre-flight validation (warns if coder == reviewer), prepares review context (`PRE_SWARM_SHA..HEAD_SHA` diff + aggregated `.result` files). Then either: **4.3a** Codex pane invokes `superpowers:requesting-code-review` from `~/.codex/superpowers/skills/requesting-code-review/`, OR **4.3b** Opus invokes `Skill("superpowers:requesting-code-review")` in-process (with two-stage SDD review: Stage 1 spec compliance, Stage 2 code quality). Fix loop addresses Critical/Important issues with up to 3 rounds per the pushback hard rule.

**See:** `references/phase-4-review.md` for sections 4.1 (reviewer determination + pre-flight), 4.2 (review context prep), 4.3a (Codex review via Superpowers skill), 4.3b (Claude two-stage review), 4.4 (fix loop).

## Phase 5 — Verification Routing

> Runs automated checks (`pytest --tb=short`, `git diff --stat`, `git status --short`), applies the **flaky test pre-filter** (rerun failing tests up to 2× with `pytest --lf`, classify as deterministic / flaky / infrastructure), classifies the verification state (`passed` / `gaps_found` / `human_needed`), and routes accordingly. The **gap closure cycle** (max 1 round, regression-gated via JUnit XML snapshots) creates targeted fix tasks rather than retrying originals. The **human-needed checklist** presents items that cannot be auto-verified.

**See:** `references/phase-5-verification.md` for sections 5.1 (automated checks), 5.2 (flaky pre-filter), 5.3 (state classification), 5.4 (gap closure cycle), 5.5 (human-needed checklist).

## Phase 6 — Done & Error Handling

> Generates `${SESSION_DIR}/report.md` with session metadata, completed tasks, files changed, test results, and review findings. Cleans up panes (unless `--keep-panes`). Presents the report to the user. Offers next steps: commit (conventional format), `superpowers:verification-before-completion` final gate, `superpowers:finishing-a-development-branch` for PR creation. The error handling table covers all failure modes (agent crash, malformed result, all agents fail, cycle, regression, gap closure regression, etc.).

**See:** `references/phase-6-and-errors.md` for the full Phase 6 report template + cleanup commands AND the complete error handling table (16 scenarios).
