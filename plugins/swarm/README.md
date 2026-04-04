# Swarm — Multi-Agent Orchestration

Manager-orchestrated multi-agent plugin for Claude Code. Uses AutoGen-style
swarm pattern with file-based inter-agent messaging and pluggable agent registry.

> **V2** — Wave-based parallel execution, 3-state verification routing, regression gates, pre-execution discuss, interrupted-session detection and resume flow.

## Usage

```
/swarm <task>                    # auto-detect complexity, run swarm
/swarm --dry-run <task>          # preview plan + team without executing
/swarm --keep-panes <task>       # keep agent panes alive after completion
/swarm --agents codex <task>     # explicitly select agents
/swarm --sequential <task>       # force strict task-by-task ordering
/swarm --resume                  # resume interrupted session
/swarm --skip-discuss <task>     # skip grey area extraction
```

## How It Works

1. Detects your terminal (cmux/tmux/plain) — adapts automatically
2. Checks for existing superpowers specs/plans — reuses them if found
3. Classifies task complexity — simple (2-agent loop) or complex (full pipeline)
4. Spawns agents from the registry, dispatches tasks as `.md` files
5. Polls for `.result` files, reviews, iterates if needed
6. Verifies (runs tests), generates report, cleans up

## Agent Registry

Edit `agents.yaml` to add new LLM backends:

```yaml
agents:
  codex:
    command_exec: "codex exec"
    command_interactive: "codex"
    roles: [coder, reviewer]
  deepseek:
    command_exec: "deepseek-cli chat"
    roles: [coder, analyst]
```

## Multiplexer Support

| Terminal | Experience |
|----------|-----------|
| CMUX | Full: visual panes + sidebar status/progress |
| tmux | Visual: agent panes side-by-side |
| Other | Headless: background processes, logs in `.swarm/logs/` |

## File Protocol

All agent communication via `.swarm/<session>/`:
- `tasks/task-NNN.md` — manager -> agent
- `tasks/task-NNN.result` — agent -> manager
- `ledger.yaml` — session state
- `report.md` — final output

## Superpowers Integration

`/swarm` sits between planning and verification in the superpowers pipeline:

```
brainstorming -> writing-plans -> /swarm -> verification -> finishing-branch
```

If no spec/plan exists, `/swarm` bootstraps by invoking brainstorming and
writing-plans first.
