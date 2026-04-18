<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-Plugin-blueviolet?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTEyIDJMMyAxNGgxOEwxMiAyeiIgZmlsbD0id2hpdGUiLz48L3N2Zz4=" alt="Claude Code Plugin"/>
  <img src="https://img.shields.io/badge/Agents-Codex_%7C_Claude-orange?style=for-the-badge" alt="Agents"/>
  <img src="https://img.shields.io/badge/Mux-CMUX_%7C_tmux-green?style=for-the-badge" alt="Multiplexer"/>
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License"/>
</p>

# 🐝 Swarm

**Multi-agent orchestration for Claude Code** — spawn AI agents in visual panes, coordinate work through file-based messaging, and close the loop with cross-review and regression gates.

```
┌─────────────────────────┬──────────────────────────┐
│  ● Claude (Orchestrator)│  ● Codex (Reviewer)      │
│                         │                          │
│  > Implementing task... │  > Reviewing changes...  │
│  ✓ Created user auth    │  Status: NEEDS_REVISION  │
│  ✓ Added tests          │  Issues:                 │
│  ✓ Updated migrations   │  - Critical: SQL inject  │
│                         │  - Minor: unused import  │
│  Waiting for review...  │                          │
└─────────────────────────┴──────────────────────────┘
```

---

## ✨ Features

<table>
<tr>
<td width="50%">

### 🎯 Visual Multi-Pane
Agents run in **side-by-side terminal panes** — watch them code, review, and fix in real time. Supports CMUX and tmux.

### 🔄 Self-Corrective Loop
Automatic criterion evaluation → revision → convergence tracking. Stalled revisions escalate early instead of cycling.

### 🛡️ Cross-Review
**Coder never reviews own code.** Claude writes → Codex reviews. Codex writes → Claude Opus reviews. Pre-flight validation prevents same-agent assignments.

</td>
<td width="50%">

### 🌊 Wave Execution
Dependency-aware task grouping with topological sort. Parallel within waves, sequential across. Cycle detection halts before dispatch.

### 📊 Regression Gates
JUnit XML baseline before execution. Between-wave regression checks. Flaky test classifier (deterministic / flaky / infrastructure).

### 🔌 Pluggable Agents
Add any CLI agent via `agents.yaml`. Model routing (haiku/sonnet/opus) for Claude agents based on task complexity.

</td>
</tr>
</table>

---

## 🚀 Quick Start

```bash
# Install: copy to your Claude Code plugins directory
cp -r swarm/ ~/.claude/local-plugins/plugins/swarm/

# Run a simple task (two-agent loop: Claude + Codex)
/swarm Fix the login timeout bug in auth.py

# Run a complex task (full pipeline with wave execution)
/swarm Build a REST API for user management with tests

# Preview without executing
/swarm --dry-run Refactor the payment module

# Use specific agents
/swarm --agents codex Implement the caching layer
```

---

## 📐 Architecture

```
                          ┌──────────────┐
                          │  /swarm CLI  │
                          └──────┬───────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                  ▼
       ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
       │   Phase 0    │   │   Phase 1    │   │  Phase 1.5  │
       │    Init      │   │  Classify    │   │  Discuss    │
       │  mux detect  │   │ simple/full  │   │ grey areas  │
       └──────┬───────┘   └──────┬───────┘   └──────┬──────┘
              │                  │                   │
              └──────────────────┼───────────────────┘
                                 ▼
                          ┌─────────────┐
                          │   Phase 2    │
                          │ Decompose   │──── task-001.md
                          │ + Waves     │──── task-002.md
                          └──────┬──────┘──── task-003.md
                                 │
                                 ▼
            ┌─────────────────────────────────────────┐
            │              Phase 3: Execute            │
            │                                          │
            │  Wave 1: ┌──────┐ ┌──────┐              │
            │          │Agent1│ │Agent2│  (parallel)   │
            │          └──┬───┘ └──┬───┘              │
            │             └────┬───┘                   │
            │          regression check                │
            │                                          │
            │  Wave 2: ┌──────┐                        │
            │          │Agent3│  (sequential)           │
            │          └──────┘                         │
            │                                          │
            │  Self-corrective loop per task:           │
            │  evaluate → revise → converge/escalate   │
            └─────────────────┬───────────────────────┘
                              │
                              ▼
                       ┌─────────────┐
                       │   Phase 4    │
                       │   Review     │
                       │ cross-agent  │
                       └──────┬──────┘
                              ▼
                       ┌─────────────┐
                       │   Phase 5    │
                       │   Verify     │
                       │ pytest+flaky │
                       └──────┬──────┘
                              ▼
                       ┌─────────────┐
                       │   Phase 6    │
                       │    Done      │
                       │ report+clean │
                       └─────────────┘
```

---

## 🔧 Agent Registry

Edit `agents.yaml` to add any CLI agent:

```yaml
agents:
  codex:
    command_exec: "codex exec"
    command_interactive: "codex --full-auto"
    roles: [coder]
    capabilities: [implement, debug]

  claude:
    command_exec: "claude --dangerously-skip-permissions -p"
    command_interactive: "claude --dangerously-skip-permissions"
    roles: [coder, researcher]
    supports_model_routing: true  # auto haiku/sonnet/opus

  # Add your own:
  my_agent:
    command_exec: "my-cli exec"
    command_interactive: "my-cli"
    roles: [coder]
```

### Model Routing

For Claude agents, tasks are auto-classified by complexity:

| Complexity | Model | Triggers |
|:-----------|:------|:---------|
| 🟢 Simple | `haiku` | fix, typo, rename, ≤2 files |
| 🟡 Standard | `sonnet` | implement, create, build, 3-5 files |
| 🔴 Complex | `opus` | refactor, architect, security, 5+ files |

---

## 🖥️ Multiplexer Support

| Terminal | Experience | Pane Layout |
|:---------|:-----------|:------------|
| **CMUX** | Full: visual panes + sidebar status/progress bar | Auto grid |
| **tmux** | Visual: agent panes side-by-side | Split h/v |
| **None** | Headless: background processes, logs in `.swarm/logs/` | N/A |

---

## 📁 File Protocol

All agent communication via `.swarm/<session>/`:

```
.swarm/swarm-20260404-165527/
├── ledger.yaml              # Session state (phase, agents, progress)
├── tasks/
│   ├── task-001.md          # Manager → Agent (assignment)
│   ├── task-001.result      # Agent → Manager (completion)
│   ├── task-001.progress    # Revision convergence tracking
│   └── task-001-rev1.md     # Revision task (if criteria failed)
├── reviews/
│   └── review-final.result  # Cross-review findings
├── logs/
│   └── agent-name.log       # Headless mode output
└── report.md                # Final session report
```

---

## 🔄 Self-Corrective Loop

```
   Task Result
       │
       ▼
  ┌──────────┐     ┌───────────┐     ┌──────────┐
  │  Step A   │────▶│  Step D   │────▶│  Step E  │
  │  Status?  │     │  Evaluate │     │  Route   │
  │ DONE/FAIL │     │  Criteria │     │          │
  └──────────┘     └───────────┘     └────┬─────┘
                                          │
                    ┌─────────────────────┼──────────────┐
                    ▼                     ▼              ▼
              ┌──────────┐         ┌──────────┐   ┌──────────┐
              │  ACCEPT  │         │  REVISE  │   │ ESCALATE │
              │  ✓ Done  │         │ max 3x   │   │  → User  │
              └──────────┘         │ converge │   └──────────┘
                                   │ tracking │
                                   └──────────┘
```

Convergence detection prevents infinite loops — if revision N doesn't improve pass count over N-1, escalates early.

---

## 🛡️ Safety

- **No MCP fallback**: Agent dispatch always goes through transport lib (visual panes), never through MCP tools
- **Command injection prevention**: `exec "$@"` pattern, no `eval`, no string interpolation
- **Atomic ledger writes**: `mktemp` + `mv`, no `sed -i`
- **YAML injection protection**: Values quoted with YAML single-quote escaping
- **Session isolation**: PID-based, with stale session detection and cleanup
- **Pane kill verification**: `cmux close-surface` as definitive final step

---

## 📋 CLI Reference

```
/swarm <task>                     Auto-detect complexity, run swarm
/swarm --dry-run <task>           Preview plan + team without executing
/swarm --keep-panes <task>        Keep agent panes alive after completion
/swarm --agents <names> <task>    Select specific agents (comma-separated)
/swarm --sequential <task>        Force strict task-by-task ordering
/swarm --resume                   Resume interrupted session
/swarm --skip-discuss <task>      Skip grey area extraction
```

---

## 🔗 Integration

Swarm sits in the [superpowers](https://github.com/anthropics/claude-code) pipeline:

```
brainstorming → writing-plans → /swarm → verification → finishing-branch
```

If no spec/plan exists, `/swarm` bootstraps by invoking brainstorming and writing-plans first.

---

<p align="center">
  <sub>Built with Claude Code + Codex · MIT License</sub>
</p>
