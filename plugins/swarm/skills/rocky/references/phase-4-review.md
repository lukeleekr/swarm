# Phase 4: Review

> Loaded by `SKILL.md` Phase 4 pointer. Contains the cross-model code review gate: reviewer determination, pre-flight validation, review context preparation, Codex review via Superpowers skill (4.3a), Claude two-stage review (4.3b), and the fix loop with pushback.

**Cross-review rule:** The reviewer must be a different agent than the coder.

| Coder Agent | Reviewer | How |
|-------------|----------|-----|
| Claude (any model) | Codex | Spawn Codex pane, then prompt `superpowers:requesting-code-review` per 4.3a |
| Codex | Claude Opus (orchestrator) | Invoke `Skill("superpowers:requesting-code-review")` → spawns `superpowers:code-reviewer` subagent |

After all tasks complete:

## 4.0 Review output schema

All code reviews (Codex via 4.3a OR Claude via 4.3b) write findings to `${SESSION_DIR}/reviews/review-final.result` using this schema. Both 4.3a and 4.3b MUST reference this section in their reviewer prompts.

````markdown
## Status
APPROVED | NEEDS_REVISION

## Strengths
- [freeform bullets]

## Issues

### Issue 1: [short title]
```yaml
severity: P0              # P0 | P1 | P2 | P3
route: coder              # coder | orchestrator | user
requires_verification: true
verification:
  runner: pytest
  target: "tests/auth/test_csrf.py::test_token_rotation"
file: src/auth/csrf.py
line: 42
```
**Description:** [what's wrong and why]
**Fix:** [what to do about it]

### Issue 2: ...

## Assessment
[freeform summary: overall verdict, risk level, recommended next step]
````

**Field rules:**

- **`severity`** — canonical scale. Do NOT use `Critical`/`Important`/`Minor` or other ad-hoc words.
  - `P0`: blocks merge. Correctness bug, security hole, data loss, broken build.
  - `P1`: must fix before release. Meaningful defect or risk.
  - `P2`: should fix. Quality issue, minor correctness nit, refactor candidate.
  - `P3`: advisory. Suggestion, style preference, future-work note.
- **`route`** — who handles the fix.
  - `coder`: dispatch back to the implementer agent via Phase 4.4 fix loop.
  - `orchestrator`: Opus addresses directly in-process (design-level decisions, not implementation).
  - `user`: escalate to human (scope, policy, or trade-off decisions the orchestrator cannot make unilaterally).
- **`requires_verification`** — boolean. When `true`, the reviewer MUST provide a `verification` block. The `verification` block is required iff `requires_verification: true`.
- **`verification`** — structured verification data. Phase 5 renders the final argv from a hardcoded runner template instead of executing a reviewer-authored command string.
  - **`runner`** — enum. Allowed identifiers and renderings are:
    - `pytest` -> `pytest [target]`
    - `rspec` -> `rspec [target]`
    - `go-test` -> `go test [target]`
    - `cargo-test` -> `cargo test [target]`
    - `npm-test` -> `npm test [target]`
    - `yarn-test` -> `yarn test [target]`
    - `pnpm-test` -> `pnpm test [target]`
    - `bundle-exec-rspec` -> `bundle exec rspec [target]`
    - `script-test` -> `./scripts/test [target]`
    - `script-verify` -> `./scripts/verify [target]`
    - Unknown runner values are rejected at execution time and counted as `verifications_missing`.
  - **`target`** — optional string. Empty or omitted is valid and means run the whole suite or the runner's default behavior.
  - **`target` constraints**:
    - MUST NOT start with `-`
    - MUST NOT start with `/`
    - MUST NOT contain whitespace
    - MUST NOT contain any of `;`, `&`, `|`, `<`, `>`, `` ` ``, `$`, `(`, `)`, `\`, newline, or null byte
    - MUST NOT contain `..` as a path component after splitting on `/`
    - length MUST be `<= 512`
    - for `go-test`, a non-empty target MUST start with `./`
  - **Valid examples**:
    - `tests/auth/test_csrf.py::test_token_rotation`
    - `./pkg/foo`
    - `./...`
    - `spec/models/user_spec.rb`
    - `""` (empty)
  - **Rejected examples**:
    - `-p mypkg`
    - `/tmp/evil_test.py`
    - `../outside/tests`
    - `github.com/attacker/evil` for runner `go-test`
    - `tests/auth test_csrf.py`
- **Why structured data instead of a command string?** Review output is machine-generated. A freeform shell command lets the reviewer choose flags and shell syntax that Phase 5 would have to sanitize after the fact. A `{runner, target}` schema closes the flag-injection category by construction because Phase 5 builds argv from a fixed template and passes it to `subprocess.run(argv, shell=False, ...)`.
- **Residual limitation (narrow, explicit):** Unlike Option F, this design does not execute a reviewer-authored command string at all. Phase 5 now treats the runner template as trusted and the selected in-repo test/package/nodeID target as project-trusted. A reviewer can still choose which in-repo tests, packages, or node IDs to run. That is an intentional project-trust boundary. Flag injection is now closed by construction.
- **Strict YAML formatting requirement:** inside the fenced `yaml` block, `requires_verification:` and `verification:` MUST start at column 0. `runner:` and `target:` MUST be indented by at least one space or tab beneath `verification:`. Top-level indentation and placement matter because Phase 5.1.5 uses a hand-rolled scanner, not a YAML parser, to read these fields. Mis-indented `verification:` top-level keys are silently skipped. `runner:` or `target:` written at column 0 are treated as top-level keys and dropped from the verification block. Inline comments are not parsed for `requires_verification:`, `runner:`, or `target:`. Use plain scalar values only, with optional surrounding quotes for `target:`; do not append `# ...` comments on those lines.
- **`file` / `line`** — optional but strongly preferred when the issue is localized.

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
swarm_pipe_prompt "${PANE}" "Use superpowers:requesting-code-review to review the code changes between ${BASE_SHA}..${HEAD_SHA}. Focus on: correctness, edge cases, security, test coverage, cross-component consistency. Write findings to ${SESSION_DIR}/reviews/review-final.result following the Section 4.0 Review output schema in this document: per-issue yaml block with severity (P0-P3), route (coder/orchestrator/user), requires_verification (bool), verification: {runner, target} (required when requires_verification is true), plus file/line when localized."
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

The skill spawns a `superpowers:code-reviewer` subagent that reviews the diff and returns structured feedback using the Section 4.0 schema (Status, Strengths, per-issue yaml with severity/route/requires_verification/verification, Assessment).

**Why two stages:** Spec compliance is fast and binary (did they build what was asked?). Code quality is deeper (is it well-built?). Running quality review on non-compliant code wastes effort.

## 4.4 Fix loop

Act on reviewer feedback per the per-issue `severity` and `route` fields (Section 4.0 schema).

**Precedence rule (read this first):** `severity` determines whether the issue *blocks* Phase 5. `route` determines *who* handles it. Severity and route are orthogonal — every combination has a defined outcome. Blocking does not require dispatch to a coder; an orchestrator or user handler can satisfy the block.

**Combined outcome matrix:**

| severity | route | Blocks Phase 5? | Handler | Action |
|---|---|---|---|---|
| P0 | coder | ✓ yes | Coder agent | Create `${SESSION_DIR}/tasks/fix-NNN.md`, dispatch via Phase 3 mechanism, re-review |
| P0 | orchestrator | ✓ yes | Opus in-process | Opus addresses directly (no subagent dispatch), re-review |
| P0 | user | ✓ yes | User | Escalate with full context, wait for direction, re-review |
| P1 | coder | ✓ yes | Coder agent | Create fix task, dispatch, re-review |
| P1 | orchestrator | ✓ yes | Opus in-process | Opus addresses directly, re-review |
| P1 | user | ✓ yes | User | Escalate, wait for direction, re-review |
| P2 | coder | ✗ no | Coder agent | Create fix task and dispatch (cheap to fix), do not re-review, note in report |
| P2 | orchestrator | ✗ no | Opus in-process | Opus addresses if time permits, otherwise note in report |
| P2 | user | ✗ no | User | Note in report, flag at Phase 6 for user attention |
| P3 | any | ✗ no | — | Note in report only. Never dispatches, never blocks. |

**Blocking** means Phase 5 does not start until the issue is resolved (handler confirms fix OR user authorizes override).

**Handler semantics:**
- `route: coder` → write a fix task file at `${SESSION_DIR}/tasks/fix-NNN.md` using the same template as Phase 2 task files, embed the full issue yaml block + description + fix hint, dispatch via the same mechanism as Phase 3.3 / 3.5 (pane or in-process SDD depending on tier).
- `route: orchestrator` → Opus resolves the issue directly in its own context — no subagent dispatch, no new task file. Used for cross-file consistency, prompt/spec edits, design judgment the coder can't make unilaterally.
- `route: user` → present the issue to the user with `file:line`, description, and fix hint. Wait for direction before proceeding. Do not auto-dispatch under any circumstance.

**Pushback rounds:** Max 3 rounds per the ORCHESTRATOR PUSHBACK hard rule across all blocking issues combined. If any `P0` or `P1` issue is still open after round 3 → escalate to user with the full issue list, routing decisions, and attempted fixes per round.

```bash
swarm_set_progress "Reviewing" "0.75"
```
