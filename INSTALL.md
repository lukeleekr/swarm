# Installing the Swarm plugin

Orientation for a fresh Claude Code session on a new machine (MacBook or otherwise). Follow the sections in order.

---

## 1. What this repo is

Swarm is a Claude Code plugin that orchestrates multi-agent coding — Claude as the manager, Codex as the reviewer (or vice versa) — through tmux panes, with cross-model code review and a self-corrective revision loop. The entry point is the skill invoked as `/swarm:rocky`.

Canonical user-facing docs live at **`plugins/swarm/README.md`** (architecture diagrams, phase breakdown, file protocol, CLI flags). Read it after finishing this install.

---

## 2. Repo layout

This repository carries two coexisting layouts. Only one is current.

| Path | Status |
|---|---|
| `plugins/swarm/` | **Canonical.** Current v2 skill (`/swarm:rocky`). All new work happens here. |
| Repo root (`agents.yaml`, `commands/swarm.md`, `lib/swarm-transport.sh`, `tests/`) | Legacy v1 flat layout (`/swarm` slash command). Kept for reference; not actively maintained. |

When installing as a Claude Code plugin, point the plugin root at **`plugins/swarm/`**, not the repo root.

---

## 3. Prerequisites

| Tool | Install | Purpose |
|---|---|---|
| Claude Code CLI | https://claude.com/claude-code | Hosts the plugin |
| Codex CLI | See https://github.com/openai/codex | Cross-model reviewer (Claude codes → Codex reviews, and vice versa) |
| tmux | `brew install tmux` | Visual panes for Tier 2/3 dispatch (optional — falls back to headless) |
| bash | preinstalled on macOS | Transport library is plain bash, no bash-4 features required |
| python3 | preinstalled on macOS | JSON parsing in phase-4 review routing |
| git | preinstalled on macOS | |

Verify each before continuing:

```bash
claude --version
codex --version
tmux -V            # optional; skip if going headless
python3 --version
```

If `codex` is missing, Tier 2/3 cross-model review cannot run. You can still use Tier 0/1 (Opus inline, single Claude subagent) but you lose the main safety benefit of the plugin.

---

## 4. Install

### 4.1 Clone the repo

```bash
git clone git@github.com:lukeleekr/swarm.git ~/workspace/swarm
# or HTTPS:
# git clone https://github.com/lukeleekr/swarm.git ~/workspace/swarm
```

You can clone anywhere — `~/workspace/swarm` is just a suggestion. The important path is the plugin subdirectory inside it: `~/workspace/swarm/plugins/swarm/`.

### 4.2 Register the plugin with Claude Code

Pick **one** of these approaches.

**Option A — Symlink into a local-plugins directory (simplest).**

```bash
mkdir -p ~/.claude/local-plugins/plugins
ln -s ~/workspace/swarm/plugins/swarm ~/.claude/local-plugins/plugins/swarm
```

Then make sure Claude Code is configured to load plugins from `~/.claude/local-plugins/` via a marketplace config or the in-app `/plugin` command. If you already have a `~/.claude/local-plugins/.claude-plugin/marketplace.json`, add an entry:

```json
{
  "name": "swarm",
  "source": "./plugins/swarm",
  "description": "Manager-orchestrated multi-agent swarm",
  "version": "1.0.0"
}
```

**Option B — Let Claude Code install it via the `/plugin` command.**

Inside a Claude Code session, run `/plugin` and follow the prompts to install from a local path, pointing it at `~/workspace/swarm/plugins/swarm`. Claude Code's current docs (https://claude.com/claude-code) have the authoritative command list.

### 4.3 Restart Claude Code

Close and reopen Claude Code so it picks up the new plugin. The skill should register as `swarm:rocky`.

---

## 5. Verify the install

In a Claude Code session with a writable git repo as the working directory:

```
/swarm:rocky --dry-run Add a trivial hello-world script
```

Expected output:
1. A Phase 0.0 tier decision line, e.g. *"Tier 0, Opus inline. No dispatch."* for a trivial task, or *"Tier 2, Codex SDD (single pane), ..."* for a feature.
2. A plan (task decomposition) with no agent dispatch.
3. No `.swarm/` session directory created (dry-run short-circuits before init).

If the skill doesn't appear at all, the symlink target or marketplace entry is wrong — double-check that it points at `plugins/swarm/` (which contains `.claude-plugin/plugin.json`), not the repo root.

---

## 6. Usage basics

```
/swarm:rocky <task>                     auto tier routing (0–3)
/swarm:rocky --dry-run <task>           plan only, no dispatch
/swarm:rocky --agents claude <task>     force Claude as coder (default is Codex)
/swarm:rocky --review-agents 2 <task>   2 parallel plan reviewers
/swarm:rocky --sequential <task>        disable wave parallelism
/swarm:rocky --keep-panes <task>        leave panes alive after completion
/swarm:rocky --resume                   resume interrupted session
/swarm:rocky --skip-discuss <task>      skip Phase 1.5/2.5 review gates
```

Full reference: `plugins/swarm/README.md`, phase docs under `plugins/swarm/skills/rocky/references/`.

---

## 7. Hard rules (for any Claude Code session using this skill)

These are operating invariants, enforced by prompts inside `SKILL.md`. Any session that violates them is breaking contract.

1. **No MCP for dispatch.** Agents are always spawned via the transport library: `swarm_spawn_agent`, `swarm_spawn_reviewer`, `swarm_pipe_prompt`, `swarm_poll_result` in `plugins/swarm/lib/swarm-transport.sh`. Never `mcp__codex__codex`.
2. **Cross-model review.** Reviewer must differ from author's model family. Claude codes → Codex reviews. Codex codes → Claude Opus reviews. Same-model review is not independent review.
3. **Max 3 pushback rounds per gate.** Orchestrator pushes back with specific concerns (file:line, missing acceptance criterion). After 3 rounds unresolved, escalate to the user. Applies at Phase 2.5 (plan review), 3.3 (REVISE), and 4.4 (fix loop).
4. **Look up commands from `agents.yaml`.** Never hardcode `"codex"` as a spawn command. Use `swarm_get_agent_field "codex" "command_interactive"` so CLI flag changes flow through one place.

---

## 8. Headless mode (no tmux)

If tmux is unavailable, agents run as background processes and their output is written to `.swarm/<session>/logs/<agent>.log`. You lose the visual multi-pane experience but orchestration still works. The multiplexer is auto-detected at Phase 0.2.

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `/swarm:rocky` does nothing / not recognized | Plugin not loaded | Check symlink target is `plugins/swarm/`, restart Claude Code. |
| `codex: command not found` during dispatch | Codex CLI missing from PATH | Install codex, or constrain work to Tier 0/1 (no cross-model review). |
| `tmux display-message` errors | Old transport lib in cache | Pull latest, make sure the plugin Claude Code loads is the symlinked path (not a stale copy). |
| Phase 0.5 refuses to init with "requires a git repo" | CWD is not inside a git repo | `cd` to the target repo first. This is intentional — Phase 4 review needs a git baseline. |
| Revisions loop forever | Should not happen — `swarm_can_revise` caps at 3 | Check `.swarm/<session>/tasks/<task>.progress` for convergence history; escalate manually. |

---

## 10. What's next

Once install is verified, read `plugins/swarm/README.md` for the full architecture and then `plugins/swarm/skills/rocky/SKILL.md` for the phase-by-phase contract the orchestrator follows.
