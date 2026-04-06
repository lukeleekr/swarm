# Phase 6: Done & Error Handling

> Loaded by `SKILL.md` Phase 6 pointer. Contains the report template, cleanup commands, next-step offers, and the complete error handling table.

## Phase 6 — Done

1. **Generate report** to `${SESSION_DIR}/report.md`:
   ```markdown
   # Swarm Report

   Session: [session_id]
   Task: [original task description]
   Duration: [elapsed time]
   Agents: [list with pane refs]
   Mux: [cmux|tmux|none]

   ## Tasks Completed
   - task-001: [title] — DONE
   - task-002: [title] — DONE

   ## Files Changed
   [aggregated list]

   ## Test Results
   [pass/fail summary]

   ## Review Findings
   [any issues found and resolved]
   ```

2. **Cleanup panes** (unless `--keep-panes`):
   ```bash
   swarm_cleanup "${SESSION_DIR}"
   ```

3. **Present report** to user.

4. **Offer next steps:**
   - "Commit these changes?" → if yes, create conventional commit
   - "Run superpowers:verification-before-completion?" → final gate
   - "Create PR?" → invoke finishing-a-development-branch

```bash
swarm_set_progress "Complete" "1.0"
swarm_log "success" "Swarm complete — ${TASKS_DONE} tasks executed"
```

## Error Handling

| Scenario | Action |
|----------|--------|
| Agent command not found | Warn user, fall back to Claude-only (Agent tool) |
| Agent timeout (5min) | Retry with simplified prompt + composure reset (1 retry). Do not add urgency language |
| Agent crash (pane dies) | Detect via `swarm_check_agent_alive`, report to user |
| `.result` malformed | Ask agent to rewrite (1 retry) |
| All external agents fail | Fall back to Claude subagents only |
| Cycle detected in wave grouping | Halt, present cycle to user for resolution |
| Regression detected between waves | Create fix task, dispatch, re-check (max 1 fix per wave) |
| Regression gate baseline unavailable | Continue without between-wave checks, warn in report |
| Flaky tests detected | Exclude from gap analysis, flag in report, route to `human_needed` |
| Infrastructure test failure | Route to `human_needed` (not auto-fix) |
| Gap closure introduces regression | Include in escalation diagnosis |
| Tests fail after gap closure | Escalate to user with full diagnosis |
| Stale session found on init | Offer cleanup |
| Interrupted session found | Offer resume (or auto-resume with `--resume`) |
| `--resume` but no interrupted session | Warn and start fresh |
| Grey areas found in plan | Present batch table, embed decisions in tasks |
| No grey areas in plan | Skip Phase 1.5 silently |
