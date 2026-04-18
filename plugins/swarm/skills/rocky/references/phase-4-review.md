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

## 4.2.5 Diff-conditioned specialist router

Specialists are additive to the core reviewer, reuse the Section 4.0 schema unchanged, and follow the same cross-model rule as the core review path. Each specialist writes `${SESSION_DIR}/reviews/review-specialist-<name>.result`. Triggers are computed once here and consumed by Section 4.3c.

| Key | Domain | `segments` (lowercase, whole-path-segment match) | `suffixes` (lowercase) | `contains` (lowercase substring) |
|---|---|---|---|---|
| `security` | Auth, crypto, session, credentials | `auth`, `crypto`, `session`, `sessions`, `credential`, `credentials`, `password`, `passwords`, `token`, `tokens`, `cookie`, `cookies`, `oauth`, `jwt`, `csrf`, `xss`, `secret`, `secrets` | `.pem`, `.key` | (empty) |
| `api-contract` | HTTP/RPC contract surface | `routes`, `controllers`, `openapi`, `swagger`, `schema`, `schemas`, `api`, `apis` | `.graphql`, `.proto` | (empty) |
| `data-migrations` | DB schema changes | `migrations`, `alembic`, `flyway`, `migrate`, `sqitch` | (empty) | `db/schema`, `/schema.sql`, `/schema.rb`, `/schema.py` |
| `performance` | Repo-specific hot paths | (empty) | (empty) | (empty) |

```bash
python3 - "${SESSION_DIR}" "${BASE_SHA}" "${HEAD_SHA}" << 'PYEOF'
import glob, json, os, subprocess, sys

if len(sys.argv) != 4:
    raise SystemExit(0)
session_dir, pre, head = sys.argv[1:4]
reviews_dir = os.path.join(session_dir, 'reviews')
specialists_json = os.path.join(reviews_dir, 'specialists.json')
for stale_path in glob.glob(f'{reviews_dir}/review-specialist-*.result'):
    try:
        os.unlink(stale_path)
    except FileNotFoundError:
        pass
try:
    os.unlink(specialists_json)
except FileNotFoundError:
    pass
changed_files = subprocess.run(
    ['git', 'diff', '--name-only', f'{pre}..{head}'],
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()
specialists = {
    'security': {'segments': ['auth', 'crypto', 'session', 'sessions', 'credential', 'credentials', 'password', 'passwords', 'token', 'tokens', 'cookie', 'cookies', 'oauth', 'jwt', 'csrf', 'xss', 'secret', 'secrets'], 'suffixes': ['.pem', '.key'], 'contains': []},
    'api-contract': {'segments': ['routes', 'controllers', 'openapi', 'swagger', 'schema', 'schemas', 'api', 'apis'], 'suffixes': ['.graphql', '.proto'], 'contains': []},
    'data-migrations': {'segments': ['migrations', 'alembic', 'flyway', 'migrate', 'sqitch'], 'suffixes': [], 'contains': ['db/schema', '/schema.sql', '/schema.rb', '/schema.py']},
    'performance': {'segments': [], 'suffixes': [], 'contains': []},
}
def matches(rule, changed_path):
    norm = changed_path.lower()
    parts = [part for part in norm.split('/') if part]
    return any(part in rule['segments'] for part in parts) or any(norm.endswith(suffix) for suffix in rule['suffixes']) or any(token in norm for token in rule['contains'])
matches_by_specialist = {}
for key, rule in specialists.items():
    triggered_files = [path for path in changed_files if matches(rule, path)]
    if triggered_files:
        matches_by_specialist[key] = triggered_files
with open(specialists_json, 'w', encoding='utf-8') as handle:
    json.dump(matches_by_specialist, handle, indent=2)
    handle.write('\n')
print(f'triggered specialists: {len(matches_by_specialist)}')
print(f'triggered files: {sum(len(paths) for paths in matches_by_specialist.values())}')
PYEOF
```

Adding a fifth specialist, or populating `performance` hot paths, means editing the Python `specialists` dict in this section directly. There is no config file, env var, or external registry for these rules.

**Zero-trigger fast path:** `specialists.json` is always written by the router, even when it is `{}`. If it parses to an empty object, Section 4.3c spawns no specialist panes or Agents. Section 4.4 still runs when `review-final.result` exists and writes `review-aggregated.result` as a structural copy of the core review; because stale specialist artifacts are deleted at the top of this router, prior rounds cannot leak into that copy.
## 4.3a Codex reviews (when coder was Claude) — invokes Superpowers skill

Spawn a Codex pane and invoke the **Superpowers `requesting-code-review` skill** from `~/.codex/superpowers/skills/requesting-code-review/`. This is symmetric to Phase 4.3b which invokes `Skill("superpowers:requesting-code-review")` on the Claude side. Same Superpowers skill, both sides.

> **Always use `swarm_spawn_reviewer` (single) or `swarm_get_agent_field` (parallel) for Codex command lookup.** Never hardcode `"codex"` as the spawn command.

**When no specialists** (simple path — wrapper handles full lifecycle):

```bash
if [ ! -s "${SESSION_DIR}/reviews/specialists.json" ] || python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); raise SystemExit(0 if not data else 1)' "${SESSION_DIR}/reviews/specialists.json"; then
  swarm_spawn_reviewer "codex" "${SESSION_DIR}" \
    "${SESSION_DIR}/reviews/review-final.result" \
    "Use superpowers:requesting-code-review to review the code changes between ${BASE_SHA}..${HEAD_SHA}. Focus on: correctness, edge cases, security, test coverage, cross-component consistency. Write findings to ${SESSION_DIR}/reviews/review-final.result following the Section 4.0 Review output schema in this document: per-issue yaml block with severity (P0-P3), route (coder/orchestrator/user), requires_verification (bool), verification: {runner, target} (required when requires_verification is true), plus file/line when localized." \
    600 "right" "" "${SESSION_DIR}/reviews/review-final.result"
fi
```

**When specialists exist** (parallel path — core pane shared with 4.3c.1 loop):

```bash
# CORE_PANE is named distinctly so the 4.3c.1 specialist loop cannot shadow it.
AGENT_CMD=$(swarm_get_agent_field "codex" "command_interactive")
CORE_PANE=$(swarm_spawn_agent "Codex-Reviewer" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "right")
swarm_register_agent "${SESSION_DIR}" "Codex-Reviewer" "${CORE_PANE}" "reviewer"
swarm_wait_agent_ready "${CORE_PANE}" 30
swarm_pipe_prompt "${CORE_PANE}" "Use superpowers:requesting-code-review to review the code changes between ${BASE_SHA}..${HEAD_SHA}. Focus on: correctness, edge cases, security, test coverage, cross-component consistency. Write findings to ${SESSION_DIR}/reviews/review-final.result following the Section 4.0 Review output schema in this document: per-issue yaml block with severity (P0-P3), route (coder/orchestrator/user), requires_verification (bool), verification: {runner, target} (required when requires_verification is true), plus file/line when localized."
# Core pane poll+kill is handled by 4.3c.1 shared wait path below.
```

On this path, the core 4.3a pane and any triggered 4.3c.1 specialist panes are spawned together immediately after Section 4.2 context prep. When `specialists.json` is non-empty, 4.3c.1 owns the shared wait/cleanup path.
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

If spec review finds issues → route back to coder for fixes (Phase 4.4). Do NOT proceed to Stage 2 or Section 4.3c.2 specialist dispatch.

**Stage 2 — Code quality** (only if Stage 1 passes):

Invoke `Skill("superpowers:requesting-code-review")` with:
- `{WHAT_WAS_IMPLEMENTED}`: aggregated task summaries
- `{PLAN_OR_REQUIREMENTS}`: original plan/spec or task description
- `{BASE_SHA}`: pre-swarm commit
- `{HEAD_SHA}`: current HEAD
- `{DESCRIPTION}`: swarm session summary

The skill spawns a `superpowers:code-reviewer` subagent that reviews the diff and returns structured feedback using the Section 4.0 schema (Status, Strengths, per-issue yaml with severity/route/requires_verification/verification, Assessment).

**Why two stages:** Spec compliance is fast and binary (did they build what was asked?). Code quality is deeper (is it well-built?). Running quality review on non-compliant code wastes effort.

If Stage 1 passes, Stage 2 and any triggered Section 4.3c.2 specialist Agents are dispatched in the same pass.

## 4.3c Dispatch specialists in parallel

Specialists follow the same opposite-model rule as the core reviewer. Claude coder means Codex specialist panes alongside Section 4.3a; Codex coder means Claude `Agent(...)` specialists alongside Section 4.3b Stage 2.

### 4.3c.1 Codex specialists (for 4.3a path, Claude coder)

Load `specialists.json` via Python, not a flat text file. If it is `{}`, do not dispatch or poll specialists; wait for the core 4.3a review to finish, then continue to Section 4.4. When it is non-empty, spawn one Codex pane per key, wait for readiness in parallel, then prompt each pane with only its triggered files.

```bash
SPECIALIST_KEYS=()
while IFS= read -r key; do
  [ -n "${key}" ] && SPECIALIST_KEYS+=("${key}")
done < <(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); [print(key) for key in data]' "${SESSION_DIR}/reviews/specialists.json")
if [ ${#SPECIALIST_KEYS[@]} -eq 0 ]; then
  echo "No specialist triggers; skip 4.3c.1"
else
  AGENT_CMD=$(swarm_get_agent_field "codex" "command_interactive")
  SPECIALIST_PANES=()
  EXPECTED_RESULTS=("${SESSION_DIR}/reviews/review-final.result")
  for key in "${SPECIALIST_KEYS[@]}"; do
    PANE=$(swarm_spawn_agent "Codex-Specialist-${key}" "${AGENT_CMD}" "$(pwd)" "${SESSION_DIR}" "right")
    SPECIALIST_PANES+=("${PANE}")
    EXPECTED_RESULTS+=("${SESSION_DIR}/reviews/review-specialist-${key}.result")
    swarm_register_agent "${SESSION_DIR}" "Codex-Specialist-${key}" "${PANE}" "reviewer"
    swarm_wait_agent_ready "${PANE}" 30 &
  done
  wait
  for i in "${!SPECIALIST_KEYS[@]}"; do
    key="${SPECIALIST_KEYS[$i]}"
    RESULT_PATH="${SESSION_DIR}/reviews/review-specialist-${key}.result"
    DOMAIN=$(python3 -c 'import sys; domains = {"security": "security - authentication, authorization, cryptography, session management, credentials, injection, secret leakage, CSRF/XSS", "api-contract": "api-contract - HTTP, RPC, schema, and contract-surface compatibility", "data-migrations": "data-migrations - schema changes, migrations, rollback safety, ordering, compatibility", "performance": "performance - repo-specific hot paths and latency-sensitive code paths"}; print(domains[sys.argv[1]])' "${key}")
    TRIGGERED_FILES=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print("\n".join(data[sys.argv[2]]))' "${SESSION_DIR}/reviews/specialists.json" "${key}")
    SPECIALIST_PROMPT=$(cat <<EOF
Domain review only: ${DOMAIN}
Session dir: ${SESSION_DIR}
Write result to: ${RESULT_PATH}
Triggered files:
${TRIGGERED_FILES}

Read only those files plus anything they import. Leave generic correctness, style, and broad architecture to the core reviewer. Write your findings using the Section 4.0 schema exactly, starting with:
## Status
APPROVED | NEEDS_REVISION

If you find no domain issues, still write an APPROVED result file and set:
## Assessment
No domain issues found in triggered files.
EOF
)
    swarm_pipe_prompt "${SPECIALIST_PANES[$i]}" "${SPECIALIST_PROMPT}"
  done
  python3 - "${EXPECTED_RESULTS[@]}" << 'PYEOF'
import os
import sys
import time

paths = sys.argv[1:]
deadline = time.monotonic() + 600
# Shared deadline: total wait is <= 600s regardless of specialist count.
while time.monotonic() < deadline:
    if all(os.path.exists(path) and os.path.getsize(path) > 0 for path in paths):
        raise SystemExit(0)
    time.sleep(2)
raise TimeoutError('Timed out waiting for core/specialist review results')
PYEOF
  for pane in "${SPECIALIST_PANES[@]}"; do swarm_kill_agent "${pane}"; done
  swarm_kill_agent "${CORE_PANE}"
fi
```

On the specialist path, start 4.3c.1 immediately after the 4.3a pane is spawned and prompted, before its standalone poll/kill step. The core reviewer pane and all specialist panes then share the same 600-second wall-clock deadline from the polling heredoc above.

### 4.3c.2 Claude specialists (for 4.3b path, Codex coder)

Stage 1 still runs first. If Stage 1 fails, exit to the Section 4.4 fix loop immediately: no specialist dispatch, no Stage 2, and no aggregation run on that iteration. If Stage 1 passes, Opus loads `specialists.json` via the same inline Python pattern as 4.3c.1 (`json.load` for keys plus per-key file lists), then dispatches one `Agent(subagent_type="superpowers:code-reviewer", name="specialist-<key>", prompt="<SPECIALIST_PROMPT>")` per key in the JSON plus the Stage 2 `Skill("superpowers:requesting-code-review")` call in the same message so they run in parallel. When `specialists.json` is `{}`, Stage 2 runs alone. Each specialist prompt includes `${SESSION_DIR}/reviews/review-specialist-<key>.result` and that key's newline-separated `{TRIGGERED_FILES}` list from the JSON. No extra polling is needed on the Claude side because `Agent(...)` calls return when complete.
### 4.3c.3 Specialist prompt template

Use one template per specialist with `{DOMAIN}`, `{TRIGGERED_FILES}`, `{RESULT_PATH}`, and `{SESSION_DIR}` filled in at dispatch time.

```text
Domain review only: {DOMAIN}
Session dir: {SESSION_DIR}
Write result to: {RESULT_PATH}
Triggered files:
{TRIGGERED_FILES}

Read only those files plus anything they import. Leave generic correctness, style, and broad architecture to the core reviewer. Write your findings to {RESULT_PATH} using the Section 4.0 schema exactly, starting with `## Status`, then `## Strengths`, `## Issues`, and `## Assessment`, with per-issue yaml containing `severity`, `route`, `requires_verification`, and `verification` when required. If you find no domain issues, still write an APPROVED result file and set Assessment to: `No domain issues found in triggered files.`
```

After Section 4.2, dispatch the core reviewer and specialists together whenever the path allows it. Section 4.3c waits only for specialist artifacts that were actually expected, and Section 4.4 does not proceed until every expected review result file is present.

## 4.4 Fix loop

Act on reviewer feedback per the per-issue `severity` and `route` fields (Section 4.0 schema).

```bash
python3 - "${SESSION_DIR}" << 'PYEOF'
import glob, os, sys

if len(sys.argv) != 2:
    raise SystemExit(0)
reviews_dir = os.path.join(sys.argv[1], 'reviews')
core_path = os.path.join(reviews_dir, 'review-final.result')
out_path = os.path.join(reviews_dir, 'review-aggregated.result')
if not os.path.exists(core_path) or os.path.getsize(core_path) == 0:
    print('aggregation skipped: review-final.result absent (Stage 1 failure path or no core review run)')
    raise SystemExit(0)
specialist_paths = sorted(glob.glob(os.path.join(reviews_dir, 'review-specialist-*.result')))
if not specialist_paths:
    with open(core_path, encoding='utf-8') as src, open(out_path, 'w', encoding='utf-8') as dst:
        dst.write(src.read())
    raise SystemExit(0)
def parse(path):
    data = {'Status': 'APPROVED', 'Strengths': [], 'Issues': [], 'Assessment': []}; section = None; issue = []
    for line in open(path, encoding='utf-8').read().splitlines():
        if line in {'## Status', '## Strengths', '## Issues', '## Assessment'}:
            if issue: data['Issues'].append('\n'.join(issue).strip()); issue = []
            section = line[3:]; continue
        if section == 'Status' and line.strip(): data['Status'] = line.strip().upper()
        elif section == 'Strengths' and line.strip(): data['Strengths'].append(line)
        elif section == 'Issues':
            if line.startswith('### Issue ') and issue: data['Issues'].append('\n'.join(issue).strip()); issue = [line]
            elif line.strip() or issue: issue.append(line)
        elif section == 'Assessment' and line.strip(): data['Assessment'].append(line.strip())
    if issue: data['Issues'].append('\n'.join(issue).strip())
    return data
sources = [('core', core_path)] + [(f"specialist-{os.path.basename(path)[18:-7]}", path) for path in specialist_paths]
parsed = [(name, parse(path)) for name, path in sources]
status = 'NEEDS_REVISION' if any(item['Status'] == 'NEEDS_REVISION' for _, item in parsed) else 'APPROVED'
strengths = [f"- [{name}] {line[2:] if line.startswith('- ') else line}" for name, item in parsed for line in item['Strengths']]
issues = [issue for _, item in parsed for issue in item['Issues']]
assessment = [f"[{name}] {line}" for name, item in parsed for line in item['Assessment']]
with open(out_path, 'w', encoding='utf-8') as handle:
    handle.write(f"## Status\n{status}\n\n## Strengths\n{chr(10).join(strengths) if strengths else '- None noted.'}\n\n## Issues\n")
    handle.write(f"{chr(10).join([''] + issues + ['']) if issues else chr(10)}## Assessment\n{chr(10).join(assessment) if assessment else 'No additional assessment.'}\n")
PYEOF
```

Aggregation runs iff `review-final.result` exists and is non-empty. When zero specialists were triggered, `review-aggregated.result` is a structural copy of `review-final.result`; when Stage 1 failed and Stage 2 never ran, aggregation is skipped and the previous aggregated artifact is left untouched until a later clean review pass overwrites it.

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
