#!/usr/bin/env bash
# swarm-transport.sh — Multiplexer abstraction + file protocol for swarm plugin
# Source this in the skill: source ~/.claude/local-plugins/plugins/swarm/lib/swarm-transport.sh
#
# NOTE: This library deliberately does NOT set `set -euo pipefail` at the top
# level — doing so leaks strict mode into the caller's shell and crashes on
# unset vars (e.g. ${REVIEW_PANES[@]} when empty). Individual functions should
# handle errors explicitly.

# ── Multiplexer Detection ─────────────────────────────────────────

swarm_detect_mux() {
  if [[ -n "${CMUX_WORKSPACE_ID:-}" ]]; then
    echo "cmux"
  elif [[ -n "${TMUX:-}" ]]; then
    echo "tmux"
  else
    echo "none"
  fi
}

# Initialize MUX cache. Re-validates on every source if the current environment
# disagrees with the cached value (handles: source outside mux → enter mux,
# in any direction: none↔tmux↔cmux).
_swarm_current_mux=$(swarm_detect_mux)
if [[ -z "${_SWARM_MUX:-}" ]] || [[ "${_SWARM_MUX}" != "${_swarm_current_mux}" ]]; then
  _SWARM_MUX="${_swarm_current_mux}"
fi
unset _swarm_current_mux

# ── Session Management ────────────────────────────────────────────

swarm_new_session() {
  local project_dir="${1:-.}"
  local session_id="swarm-$(date +%Y%m%d-%H%M%S)"
  local session_dir="${project_dir}/.swarm/${session_id}"
  mkdir -p "${session_dir}"/{tasks,reviews,logs}
  echo "${session_id}"
}

swarm_init_ledger() {
  local session_dir="$1"
  local session_id="$2"
  local mux="$3"
  cat > "${session_dir}/ledger.yaml" << EOF
session_id: '${session_id//\'/"''"}'
phase: init
plan_source: null
mux: '${mux//\'/"''"}'
tasks_total: 0
tasks_done: 0
wave_count: 0
current_wave: 0
regression_gate: null
verification_state: null
gap_closure_round: 0
tasks_completed: []
resumed_from: null
manager_pid: $$
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
agents: []
EOF
}

swarm_update_ledger_field() {
  local session_dir="$1"
  local field="$2"
  local value="$3"
  local ledger="${session_dir}/ledger.yaml"
  if [[ -f "${ledger}" ]]; then
    # Escape sed metacharacters in field and value
    local esc_field esc_value
    esc_field=$(printf '%s' "${field}" | sed 's/[&/\]/\\&/g')
    esc_value=$(printf '%s' "${value}" | sed 's/[&/\]/\\&/g')
    local tmp
    tmp=$(mktemp "${ledger}.XXXXXX")
    sed "s|^${esc_field}: .*|${esc_field}: ${esc_value}|" "${ledger}" \
      | sed "s|^updated: .*|updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)|" \
      > "${tmp}" && mv "${tmp}" "${ledger}" || { rm -f "${tmp}"; return 1; }
  fi
}

swarm_register_agent() {
  local session_dir="$1"
  local name="$2"
  local pane_id="$3"
  local role="${4:-worker}"
  local ledger="${session_dir}/ledger.yaml"
  if [[ -f "${ledger}" ]]; then
    local tmp
    # Replace empty agents list or append to existing entries
    if grep -q 'agents: \[\]' "${ledger}"; then
      tmp=$(mktemp "${ledger}.XXXXXX")
      sed "s/^agents: \[\]/agents:/" "${ledger}" > "${tmp}" && mv "${tmp}" "${ledger}" || { rm -f "${tmp}"; return 1; }
    fi
    # Quote name and role for YAML safety; pane_id left unquoted (parsed by cleanup)
    local safe_name="${name//\'/"''"}"
    local safe_role="${role//\'/"''"}"
    cat >> "${ledger}" << EOF
  - name: '${safe_name}'
    pane_id: ${pane_id}
    role: '${safe_role}'
    status: idle
EOF
    tmp=$(mktemp "${ledger}.XXXXXX")
    sed "s/^updated: .*/updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)/" "${ledger}" > "${tmp}" && mv "${tmp}" "${ledger}" || { rm -f "${tmp}"; return 1; }
  fi
}

# ── Agent Spawning ────────────────────────────────────────────────

swarm_spawn_agent() {
  local name="$1"
  local command="$2"
  local workdir="$3"
  local session_dir="$4"
  local split_dir="${5:-right}"    # right or down
  local split_from="${6:-}"        # surface to split from (optional)
  local mux="${_SWARM_MUX:-$(swarm_detect_mux)}"

  local pane_id=""
  case "${mux}" in
    cmux)
      local output
      if [[ -n "${split_from}" ]]; then
        output=$(cmux new-split "${split_dir}" --surface "${split_from}" 2>/dev/null || echo "")
      else
        output=$(cmux new-split "${split_dir}" 2>/dev/null || echo "")
      fi
      pane_id=$(echo "${output}" | grep -o 'surface:[0-9]*' | head -1)
      if [[ -n "${pane_id}" ]]; then
        # Send cd and command separately to avoid shell interpolation issues
        cmux send --surface "${pane_id}" "cd $(printf '%q' "${workdir}")" >/dev/null 2>&1
        cmux send-key --surface "${pane_id}" Enter >/dev/null 2>&1
        cmux send --surface "${pane_id}" "${command}" >/dev/null 2>&1
        cmux send-key --surface "${pane_id}" Enter >/dev/null 2>&1
        cmux rename-tab --surface "${pane_id}" "${name}" >/dev/null 2>&1 || true
      fi
      ;;
    tmux)
      # Map split_dir to tmux flags: right=-h, down=-v
      local tmux_split_flag="-h"
      [[ "${split_dir}" == "down" ]] && tmux_split_flag="-v"
      # Capture stderr to session log so spawn failures are visible.
      # Wrap the CLI in `bash -c 'cmd; exec bash'` so the pane survives a CLI
      # crash — symmetric with cmux which runs a shell underneath.
      local spawn_err="${session_dir}/logs/spawn-${name}.err"
      mkdir -p "${session_dir}/logs" 2>/dev/null
      local wrapped="${command}; exec bash"
      if [[ -n "${split_from}" ]]; then
        pane_id=$(tmux split-window ${tmux_split_flag} -t "${split_from}" -d -c "${workdir}" -P -F '#{pane_id}' -- bash -c "${wrapped}" 2>"${spawn_err}")
      else
        pane_id=$(tmux split-window ${tmux_split_flag} -d -c "${workdir}" -P -F '#{pane_id}' -- bash -c "${wrapped}" 2>"${spawn_err}")
      fi
      if [[ -z "${pane_id}" ]]; then
        echo "ERROR: tmux split-window failed for ${name}: $(cat "${spawn_err}" 2>/dev/null)" >&2
        return 1
      fi
      ;;
    none)
      local log_file="${session_dir}/logs/${name}.log"
      mkdir -p "${session_dir}/logs" 2>/dev/null
      # `${command}` is a single shell-quoted command string from the registry
      # (e.g. `python3 -c 'import sys; print(sys.argv[1])' 'hello world'`).
      # `read -a` would re-split and lose the quoting, so we delegate parsing
      # to a real shell via `bash -c "${command}"`. This preserves quoted args
      # exactly as the registry author wrote them.
      nohup bash -c "cd $(printf '%q' "${workdir}") && exec ${command}" \
        > "${log_file}" 2>&1 &
      pane_id="pid:$!"
      ;;
  esac

  echo "${pane_id}"
}

swarm_wait_agent_ready() {
  # Wait for an agent pane to be ready to accept input.
  # Auto-accepts trust/folder prompts (Codex and Claude CLI).
  # Returns 0 when ready, 1 on timeout.
  local pane_id="$1"
  local timeout="${2:-30}"
  local mux="${_SWARM_MUX:-$(swarm_detect_mux)}"

  [[ "${mux}" == "none" ]] && return 0  # headless: always ready

  local elapsed=0
  while (( elapsed < timeout )); do
    local screen
    case "${mux}" in
      cmux) screen=$(cmux read-screen --surface "${pane_id}" --lines 25 2>/dev/null) ;;
      tmux) screen=$(tmux capture-pane -t "${pane_id}" -p 2>/dev/null) ;;
      *)    return 0 ;;
    esac
    screen="${screen:-}"

    # Detect trust/approval prompts and auto-accept
    # Numbered menu (Codex): "Yes, continue" pre-selected → just Enter
    # Text Y/n prompt → send "y" + Enter
    if echo "${screen}" | grep -qiE \
        'trust.*(folder|directory|contents)|Do you trust|Press enter to continue|Yes,.*continue'; then
      case "${mux}" in
        cmux) cmux send-key --surface "${pane_id}" Enter 2>/dev/null || true ;;
        tmux) tmux send-keys -t "${pane_id}" Enter 2>/dev/null || true ;;
      esac
      sleep 3
      elapsed=$((elapsed + 3))
      continue
    fi
    if echo "${screen}" | grep -qiE '\(Y\/n\)|\[Y\/n\]|Allow.*access|approve.*path|grant.*access|allow codex'; then
      case "${mux}" in
        cmux)
          cmux send --surface "${pane_id}" "y" 2>/dev/null || true
          cmux send-key --surface "${pane_id}" Enter 2>/dev/null || true
          ;;
        tmux) tmux send-keys -t "${pane_id}" "y" Enter 2>/dev/null || true ;;
      esac
      sleep 3
      elapsed=$((elapsed + 3))
      continue
    fi

    # Agent ready detection — two signals:
    # (1) Whole-screen markers for TUI apps in steady state
    # (2) Last non-empty line looks like a CLI prompt
    #
    # Markers (any one matches = ready):
    # - `·[[:space:]]+[0-9]+%[[:space:]]+l` — Codex status bar "· 100% left".
    #   Matches `l` rather than literal "left" because Codex truncates the
    #   status line to "100% le…" in narrow panes. The leading middle dot
    #   prefix gates against pytest false positives like "25% left" (no dot).
    # - `>_[[:space:]]+OpenAI Codex` — the Codex welcome banner identifier,
    #   the most reliable early-ready signal, present from the moment the
    #   Codex TUI renders its greeting box.
    # - `gpt-5\.[0-9]+[[:space:]]+(high|medium|low)[[:space:]]+fast` — Codex
    #   model-name banner. Uses `[[:space:]]+` (not literal single space)
    #   because the welcome screen shows `model:   gpt-5.4 high   fast`
    #   with multi-space column alignment, while the status bar shows
    #   `gpt-5.4 high fast` single-spaced. Both forms now match.
    # - `bypass permissions on` / `Context [░▒▓█]` — Claude CLI ready markers.
    if echo "${screen}" | grep -qE \
        '·[[:space:]]+[0-9]+%[[:space:]]+l|>_[[:space:]]+OpenAI Codex|gpt-5\.[0-9]+[[:space:]]+(high|medium|low)[[:space:]]+fast|bypass permissions on|Context [░▒▓█]'; then
      return 0
    fi
    local last_line
    last_line=$(printf '%s\n' "${screen}" | awk 'NF {last=$0} END {print last}')
    # Prompt detection on the last non-empty line.
    # Shell prompt: ends with $/%/# possibly followed by space.
    #   Examples that match: "bash-3.2$", "user@host ~ %", "root@box # "
    #   Excludes "</div>" or "10 > 5" because we require $/%/# (not >).
    # REPL prompt: ">" only when at start of line (e.g. "> ") or "❯/›" prefix.
    #   "10 > 5" won't match because > is mid-line, not at start.
    if [[ "${last_line}" =~ [\$%#][[:space:]]*$ ]] \
       || [[ "${last_line}" =~ ^[\>❯›][[:space:]] ]]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

swarm_kill_agent() {
  local pane_id="$1"
  local mux="${_SWARM_MUX:-$(swarm_detect_mux)}"

  case "${mux}" in
    cmux)
      if [[ "${pane_id}" == surface:* ]]; then
        # 1. Ctrl+C — interrupt running process
        cmux send-key --surface "${pane_id}" ctrl+c 2>/dev/null || true
        sleep 0.5
        # 2. /exit — exit Claude CLI / Codex CLI
        cmux send --surface "${pane_id}" "/exit" 2>/dev/null || true
        cmux send-key --surface "${pane_id}" Enter 2>/dev/null || true
        sleep 2
        # 3. exit — exit the shell
        cmux send --surface "${pane_id}" "exit" 2>/dev/null || true
        cmux send-key --surface "${pane_id}" Enter 2>/dev/null || true
        sleep 1
        # 4. Force close: cmux close-surface is the definitive kill
        cmux close-surface --surface "${pane_id}" 2>/dev/null || true
      fi
      ;;
    tmux)
      # Mirror cmux graceful sequence: Ctrl-C → /exit → exit → kill-pane
      # Gives Codex/Claude CLI a chance to flush state before force-kill.
      tmux send-keys -t "${pane_id}" C-c 2>/dev/null || true
      sleep 0.5
      tmux send-keys -t "${pane_id}" "/exit" Enter 2>/dev/null || true
      sleep 1
      tmux send-keys -t "${pane_id}" "exit" Enter 2>/dev/null || true
      sleep 0.5
      tmux kill-pane -t "${pane_id}" 2>/dev/null || true
      ;;
    none)
      if [[ "${pane_id}" == pid:* ]]; then
        local pid="${pane_id#pid:}"
        kill "${pid}" 2>/dev/null || true
        sleep 1
        if kill -0 "${pid}" 2>/dev/null; then
          kill -9 "${pid}" 2>/dev/null || true
        fi
      fi
      ;;
  esac
}

swarm_check_agent_alive() {
  local pane_id="$1"
  local mux="${_SWARM_MUX:-$(swarm_detect_mux)}"

  case "${mux}" in
    cmux)
      cmux read-screen --surface "${pane_id}" --lines 1 >/dev/null 2>&1
      ;;
    tmux)
      tmux display-message -p -t "${pane_id}" '#{pane_id}' >/dev/null 2>&1
      ;;
    none)
      if [[ "${pane_id}" == pid:* ]]; then
        local pid="${pane_id#pid:}"
        kill -0 "${pid}" 2>/dev/null
      fi
      ;;
  esac
}

# ── File Protocol ─────────────────────────────────────────────────

swarm_write_task() {
  local session_dir="$1"
  local task_num="$2"
  local content="$3"
  [[ -d "${session_dir}/tasks" ]] || { echo "ERROR: tasks dir missing: ${session_dir}/tasks" >&2; return 1; }
  local task_file="${session_dir}/tasks/task-$(printf '%03d' "${task_num}").md"
  echo "${content}" > "${task_file}"
  echo "${task_file}"
}

swarm_check_result() {
  local task_file="$1"
  local result_file="${task_file%.md}.result"
  # Only accept results that contain the completion marker
  [[ -f "${result_file}" ]] && [[ -s "${result_file}" ]] && grep -q '^Status:' "${result_file}"
}

swarm_read_result() {
  local task_file="$1"
  local result_file="${task_file%.md}.result"
  if [[ -f "${result_file}" ]]; then
    cat "${result_file}"
  else
    echo ""
  fi
}

swarm_clear_result() {
  # Remove stale .result before retrying a task
  local task_file="$1"
  local result_file="${task_file%.md}.result"
  rm -f "${result_file}"
}

swarm_poll_result() {
  local task_file="$1"
  local timeout="${2:-300}"
  local interval="${3:-5}"
  local elapsed=0

  # Validate task file exists (skip for review files which have no .md counterpart)
  if [[ "${task_file}" != */reviews/* ]] && [[ ! -f "${task_file}" ]]; then
    echo "ERROR: task file not found: ${task_file}" >&2
    return 1
  fi

  while (( elapsed < timeout )); do
    if swarm_check_result "${task_file}"; then
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
  return 1
}

# ── Agent Prompt Piping ───────────────────────────────────────────

swarm_pipe_prompt() {
  local pane_id="$1"
  local prompt="$2"
  local mux="${_SWARM_MUX:-$(swarm_detect_mux)}"

  # Wait for agent to be ready before sending
  if [[ "${mux}" != "none" ]]; then
    swarm_wait_agent_ready "${pane_id}" 30 || {
      echo "WARNING: agent ${pane_id} not ready after 30s, sending anyway" >&2
    }
  fi

  case "${mux}" in
    cmux)
      cmux send --surface "${pane_id}" "${prompt}" >/dev/null 2>&1
      cmux send-key --surface "${pane_id}" Enter >/dev/null 2>&1
      ;;
    tmux)
      # CRITICAL: use load-buffer + paste-buffer for multi-line safety.
      # `tmux send-keys "${prompt}" Enter` treats embedded \n as Enter keypresses,
      # so any multi-line prompt gets submitted at the first newline.
      # Writing the prompt to a buffer and pasting preserves exact content.
      #
      # Hard rule: ALWAYS send Enter as a separate keystroke after the paste.
      # Codex/Claude CLIs do not auto-submit on paste — Enter must be explicit.
      local tmp_buf buf_name="swarm-prompt-$$"
      tmp_buf=$(mktemp -t swarm-prompt.XXXXXX)
      printf '%s' "${prompt}" > "${tmp_buf}"
      _swarm_pp_cleanup() {
        rm -f "${tmp_buf}"
        tmux delete-buffer -b "${buf_name}" 2>/dev/null || true
      }
      if ! tmux load-buffer -b "${buf_name}" "${tmp_buf}" 2>/dev/null; then
        echo "ERROR: tmux load-buffer failed for pane ${pane_id}" >&2
        _swarm_pp_cleanup
        return 1
      fi
      if ! tmux paste-buffer -b "${buf_name}" -d -t "${pane_id}" 2>/dev/null; then
        echo "ERROR: tmux paste-buffer failed for pane ${pane_id}" >&2
        _swarm_pp_cleanup
        return 1
      fi
      # Small settle for Codex TUI to absorb the paste before Enter.
      sleep 0.3
      if ! tmux send-keys -t "${pane_id}" Enter 2>/dev/null; then
        echo "ERROR: tmux send-keys Enter failed for pane ${pane_id}" >&2
        _swarm_pp_cleanup
        return 1
      fi
      _swarm_pp_cleanup
      ;;
    none)
      # For background processes, prompt was already given at spawn time.
      :
      ;;
  esac
}

# ── CMUX Sidebar (optional enhancements) ─────────────────────────

swarm_set_status() {
  local role="$1"
  local mux="${_SWARM_MUX:-$(swarm_detect_mux)}"
  if [[ "${mux}" == "cmux" ]]; then
    cmux set-status "role" "${role}" --icon "robot.fill" --color "#4CAF50" 2>/dev/null || true
  fi
}

swarm_set_progress() {
  local label="$1"
  local progress="$2"
  local mux="${_SWARM_MUX:-$(swarm_detect_mux)}"
  if [[ "${mux}" == "cmux" ]]; then
    cmux set-progress "${progress}" --label "${label}" 2>/dev/null || true
  fi
}

swarm_log() {
  local level="${1:-info}"
  local message="$2"
  local mux="${_SWARM_MUX:-$(swarm_detect_mux)}"
  if [[ "${mux}" == "cmux" ]]; then
    cmux log --level "${level}" "${message}" 2>/dev/null || true
  fi
}

# ── Cleanup ───────────────────────────────────────────────────────

swarm_cleanup() {
  local session_dir="$1"
  local ledger="${session_dir}/ledger.yaml"

  if [[ ! -f "${ledger}" ]]; then return 0; fi

  while IFS= read -r pane_id; do
    [[ -n "${pane_id}" ]] && swarm_kill_agent "${pane_id}"
  done < <(grep 'pane_id:' "${ledger}" 2>/dev/null | awk '{print $2}')

  # Verify all panes are actually gone
  while IFS= read -r pane_id; do
    if [[ -n "${pane_id}" ]] && swarm_check_agent_alive "${pane_id}" 2>/dev/null; then
      swarm_log "warning" "Pane ${pane_id} still alive after cleanup"
    fi
  done < <(grep 'pane_id:' "${ledger}" 2>/dev/null | awk '{print $2}')

  swarm_update_ledger_field "${session_dir}" "phase" "done"
  swarm_set_progress "Done" "1.0"
  swarm_log "success" "Swarm session complete"
}

# ── Stale Session Detection ──────────────────────────────────────

swarm_find_stale_sessions() {
  local project_dir="${1:-.}"
  local swarm_dir="${project_dir}/.swarm"
  [[ -d "${swarm_dir}" ]] || return 0
  local stale=()
  while IFS= read -r ledger; do
    local phase pid
    phase=$(grep '^phase:' "${ledger}" | awk '{print $2}')
    pid=$(grep '^manager_pid:' "${ledger}" | awk '{print $2}')
    # Only stale if: phase != done AND manager PID is dead
    if [[ "${phase}" != "done" && -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
      stale+=("$(dirname "${ledger}")")
    fi
  done < <(find "${swarm_dir}" -maxdepth 2 -name "ledger.yaml" 2>/dev/null)
  if (( ${#stale[@]} > 0 )); then
    printf '%s\n' "${stale[@]}"
  fi
}

# ── Gitignore ─────────────────────────────────────────────────────

swarm_ensure_gitignore() {
  local project_dir="${1:-.}"
  # Only act inside git repos
  git -C "${project_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if ! grep -q '.swarm/' "${project_dir}/.gitignore" 2>/dev/null; then
    echo '.swarm/' >> "${project_dir}/.gitignore"
  fi
}

# ── Plugin Cache Sync ────────────────────────────────────────────
#
# Rocky source files live under ~/.claude/local-plugins/plugins/<name>/...
# but Claude Code reads from ~/.claude/plugins/cache/local-plugins/<name>/<version>/...
# at runtime. Every source edit must be mirrored into the cache or the runtime
# continues executing stale code. Manual `cp` is error-prone — a typo or a
# forgotten sync has been observed to silently defeat real bug fixes (see
# project_swarm_rocky_internal_bugs.md in user memory). These helpers
# automate and validate the mirror.

# Compute cache path for a given plugin source file.
# Echoes the cache path on stdout, returns 0 on success, 1 on unrecognized input.
swarm_plugin_cache_path() {
  local src_file="$1"
  local src_prefix="${HOME}/.claude/local-plugins/plugins/"
  if [[ "${src_file}" != "${src_prefix}"* ]]; then
    return 1
  fi
  local rel="${src_file#${src_prefix}}"
  local plugin_name="${rel%%/*}"
  local rel_within="${rel#${plugin_name}/}"
  # Read version from plugin.json if present; fall back to highest numeric
  # directory under the cache root.
  local plugin_version=""
  local manifest="${src_prefix}${plugin_name}/.claude-plugin/plugin.json"
  if [[ -f "${manifest}" ]]; then
    plugin_version=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "${manifest}" 2>/dev/null \
      | head -1 \
      | sed 's/.*"\([^"]*\)"$/\1/')
  fi
  if [[ -z "${plugin_version}" ]]; then
    local cache_root="${HOME}/.claude/plugins/cache/local-plugins/${plugin_name}"
    plugin_version=$(ls -1 "${cache_root}" 2>/dev/null | grep -E '^[0-9]' | sort -V | tail -1)
  fi
  if [[ -z "${plugin_version}" ]]; then
    return 1
  fi
  printf '%s\n' "${HOME}/.claude/plugins/cache/local-plugins/${plugin_name}/${plugin_version}/${rel_within}"
  return 0
}

# Sync a single plugin source file to its cache counterpart.
# Creates parent dirs if needed. Verifies byte-identical with cmp after copy.
# Returns 0 on success, 1 on any failure.
swarm_sync_plugin_cache() {
  local src_file="$1"
  if [[ ! -f "${src_file}" ]]; then
    echo "swarm_sync_plugin_cache: source not found: ${src_file}" >&2
    return 1
  fi
  local dst_file
  dst_file=$(swarm_plugin_cache_path "${src_file}")
  if [[ -z "${dst_file}" ]]; then
    echo "swarm_sync_plugin_cache: cannot compute cache path for ${src_file}" >&2
    return 1
  fi
  mkdir -p "$(dirname "${dst_file}")" 2>/dev/null || {
    echo "swarm_sync_plugin_cache: mkdir failed for $(dirname "${dst_file}")" >&2
    return 1
  }
  cp "${src_file}" "${dst_file}" || {
    echo "swarm_sync_plugin_cache: cp failed ${src_file} -> ${dst_file}" >&2
    return 1
  }
  if ! cmp -s "${src_file}" "${dst_file}"; then
    echo "swarm_sync_plugin_cache: post-sync cmp mismatch ${src_file} vs ${dst_file}" >&2
    return 1
  fi
  return 0
}

# Check whether all tracked plugin source files match their cache counterparts.
# Scans lib/*.sh, SKILL.md, and references/*.md under the given plugin.
# Prints a `divergent: <relpath>` line for each mismatch; prints nothing on
# full parity. Returns 0 if in sync, 1 if any divergence, 2 on config error.
# Intended for Phase 0 init as a best-effort warning — does not error out
# the init, only surfaces staleness.
swarm_validate_cache_sync() {
  local plugin_name="${1:-swarm}"
  local src_root="${HOME}/.claude/local-plugins/plugins/${plugin_name}"
  [[ -d "${src_root}" ]] || { echo "swarm_validate_cache_sync: no source for ${plugin_name}" >&2; return 2; }
  local divergent=0
  local src_file rel_path cache_file
  # Walk key files only — lib + skills (SKILL.md and references).
  # Avoid traversing .git, evals, or other non-runtime dirs.
  for src_file in \
      "${src_root}/lib"/*.sh \
      "${src_root}/skills"/*/SKILL.md \
      "${src_root}/skills"/*/references/*.md; do
    [[ -f "${src_file}" ]] || continue
    cache_file=$(swarm_plugin_cache_path "${src_file}") || continue
    if [[ ! -f "${cache_file}" ]]; then
      rel_path="${src_file#${src_root}/}"
      printf 'divergent: %s (missing in cache)\n' "${rel_path}"
      divergent=$((divergent + 1))
    elif ! cmp -s "${src_file}" "${cache_file}"; then
      rel_path="${src_file#${src_root}/}"
      printf 'divergent: %s\n' "${rel_path}"
      divergent=$((divergent + 1))
    fi
  done
  [[ ${divergent} -eq 0 ]] && return 0
  return 1
}

# ── Wave Grouping ────────────────────────────────────────────────

swarm_group_waves() {
  # Reads task files, builds dependency graph, returns wave assignments.
  # Uses inline Python for topological sort + cycle detection.
  # Exit codes: 0=success, 2=cycle detected
  local session_dir="$1"
  local tasks_dir="${session_dir}/tasks"

  python3 - "${tasks_dir}" << 'PYEOF'
import sys, re, os
from collections import defaultdict

tasks_dir = sys.argv[1]
task_files = sorted(f for f in os.listdir(tasks_dir) if f.startswith("task-") and f.endswith(".md"))

if not task_files:
    sys.exit(0)

# Parse each task for "Depends On" and "Files to Touch"
task_deps = {}      # task_id -> set of explicit dependency task_ids
task_files_map = {}  # task_id -> set of file paths
task_ids = []

for tf in task_files:
    task_id = tf.replace(".md", "")
    task_ids.append(task_id)
    task_deps[task_id] = set()
    task_files_map[task_id] = set()

    with open(os.path.join(tasks_dir, tf)) as fh:
        content = fh.read()

    # Parse "## Depends On" section
    dep_match = re.search(r'## Depends On\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
    if dep_match:
        for line in dep_match.group(1).strip().splitlines():
            line = line.strip().lstrip("- ").split("#")[0].strip()
            if line:
                task_deps[task_id].add(line)

    # Parse "## Files to Touch" section
    files_match = re.search(r'## Files to Touch\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
    if files_match:
        for line in files_match.group(1).strip().splitlines():
            line = line.strip().lstrip("- ").split("#")[0].strip()
            if line:
                task_files_map[task_id].add(line)

# Build directed dependency graph
graph = defaultdict(set)  # task_id -> set of tasks it depends on
for tid in task_ids:
    graph[tid] = set(task_deps[tid])

# Add file-overlap edges (later task depends on earlier)
for i, t1 in enumerate(task_ids):
    for t2 in task_ids[i+1:]:
        if task_files_map[t1] & task_files_map[t2]:
            graph[t2].add(t1)

# Topological sort (Kahn's algorithm) with cycle detection
in_degree = {tid: 0 for tid in task_ids}
adj = defaultdict(set)  # forward edges: dep -> dependents
for tid in task_ids:
    for dep in graph[tid]:
        if dep in in_degree:
            adj[dep].add(tid)
            in_degree[tid] += 1

queue = [tid for tid in task_ids if in_degree[tid] == 0]
waves = {}
wave_num = 1
processed = 0

while queue:
    next_queue = []
    # Tasks with unknown file scope (empty Files to Touch) get solo waves
    normal = [t for t in queue if task_files_map.get(t)]
    unknown = [t for t in queue if not task_files_map.get(t)]

    if normal:
        for tid in normal:
            waves[tid] = wave_num
            processed += 1
        wave_num += 1

    for tid in unknown:
        waves[tid] = wave_num
        processed += 1
        wave_num += 1

    for tid in queue:
        for dep_tid in adj[tid]:
            in_degree[dep_tid] -= 1
            if in_degree[dep_tid] == 0:
                next_queue.append(dep_tid)
    queue = sorted(next_queue)

# Cycle detection
if processed < len(task_ids):
    remaining = [tid for tid in task_ids if tid not in waves]
    print(f"CYCLE_DETECTED: {' -> '.join(remaining)}", file=sys.stderr)
    sys.exit(2)

for tid in task_ids:
    print(f"{tid}:{waves[tid]}")
PYEOF
}

# ── Regression Gate ──────────────────────────────────────────────

swarm_capture_test_baseline() {
  # Capture JUnit XML baseline before execution.
  # Returns: "baseline" on success, "unavailable" on failure.
  # Note: pytest exit code doesn't matter — even a red baseline is valid
  # (it records which tests currently pass for regression comparison).
  local session_dir="$1"
  local xml_path="${session_dir}/test-baseline.xml"

  pytest --tb=no -q --junitxml="${xml_path}" 2>/dev/null || true

  if [[ -f "${xml_path}" ]] && [[ -s "${xml_path}" ]]; then
    echo "baseline"
  else
    echo "unavailable"
  fi
}

swarm_extract_passing_tests() {
  # Parse JUnit XML, output one passing test ID per line.
  local xml_path="$1"
  [[ -f "${xml_path}" ]] || return 0

  python3 - "${xml_path}" << 'PYEOF'
import sys, xml.etree.ElementTree as ET

tree = ET.parse(sys.argv[1])
for tc in tree.iter("testcase"):
    classname = tc.get("classname", "")
    name = tc.get("name", "")
    # A test passes if it has no failure/error/skipped children
    if not any(tc.iter("failure")) and not any(tc.iter("error")) and not any(tc.iter("skipped")):
        test_id = f"{classname}::{name}" if classname else name
        print(test_id)
PYEOF
}

swarm_check_regression() {
  # Compare wave test results against baseline by test identity.
  # Returns 0 if clean, 1 if regression detected.
  # Outputs regressed test IDs to stdout.
  local session_dir="$1"
  local wave_num="$2"
  local baseline_xml="${session_dir}/test-baseline.xml"
  local wave_xml="${session_dir}/test-wave-${wave_num}.xml"

  if [[ ! -f "${baseline_xml}" ]]; then
    echo "skipped"
    return 0
  fi

  # Run tests and capture wave XML
  pytest --tb=line -q --junitxml="${wave_xml}" 2>/dev/null || true

  if [[ ! -f "${wave_xml}" ]]; then
    echo "skipped"
    return 0
  fi

  # Compare passing test sets
  local baseline_passing wave_passing
  baseline_passing=$(swarm_extract_passing_tests "${baseline_xml}" | sort)
  wave_passing=$(swarm_extract_passing_tests "${wave_xml}" | sort)

  # Find tests that passed in baseline but not in wave (regressions)
  local regressions
  regressions=$(comm -23 <(echo "${baseline_passing}") <(echo "${wave_passing}"))

  if [[ -n "${regressions}" ]]; then
    echo "${regressions}"
    return 1
  fi

  return 0
}

# ── Flaky Test Detection ─────────────────────────────────────────

swarm_extract_failing_tests() {
  # Parse pytest output (text, not XML) and extract failing test IDs.
  # Expects pytest --tb=short or --tb=line output on stdin or as file arg.
  local input="${1:-/dev/stdin}"
  # Match lines like "FAILED tests/test_foo.py::test_bar - AssertionError"
  grep -E '^FAILED ' "${input}" 2>/dev/null | sed 's/^FAILED //' | sed 's/ - .*//'
}

swarm_classify_test_failures() {
  # Rerun failing tests up to 2 times, classify each as:
  #   deterministic — fails every run (real bug)
  #   flaky — passes on retry (unreliable test)
  #   infrastructure — ImportError, ConnectionRefused, timeout (env issue)
  # Usage: swarm_classify_test_failures "$session_dir" "test_id1 test_id2 ..."
  # Outputs one line per test: "test_id:classification"
  local session_dir="$1"
  shift
  local test_ids=("$@")
  local infra_patterns='ImportError|ModuleNotFoundError|ConnectionRefused|TimeoutError|OSError'

  for test_id in "${test_ids[@]}"; do
    # Check for infrastructure error in original output
    local original_output="${session_dir}/verify-pytest.txt"
    if [[ -f "${original_output}" ]] && grep -qE "${infra_patterns}" "${original_output}" 2>/dev/null; then
      # Verify this test specifically has infra error
      if grep -A5 "${test_id}" "${original_output}" 2>/dev/null | grep -qE "${infra_patterns}"; then
        echo "${test_id}:infrastructure"
        continue
      fi
    fi

    # Retry the test up to 2 times
    local passed=false
    for _retry in 1 2; do
      if pytest "${test_id}" --tb=no -q 2>/dev/null; then
        passed=true
        break
      fi
    done

    if [[ "${passed}" == true ]]; then
      echo "${test_id}:flaky"
    else
      echo "${test_id}:deterministic"
    fi
  done
}

# ── Session Resume ───────────────────────────────────────────────

swarm_find_interrupted_sessions() {
  # Like swarm_find_stale_sessions but requires partial progress (.result files)
  local project_dir="${1:-.}"
  local swarm_dir="${project_dir}/.swarm"
  [[ -d "${swarm_dir}" ]] || return 0
  while IFS= read -r ledger; do
    local session_dir
    session_dir=$(dirname "${ledger}")
    local phase
    phase=$(grep '^phase:' "${ledger}" | awk '{print $2}')
    local pid
    pid=$(grep '^manager_pid:' "${ledger}" | awk '{print $2}')
    # Only interrupted if: phase != done AND manager PID is dead
    if [[ "${phase}" != "done" && -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
      local results
      results=$(find "${session_dir}/tasks" -name "*.result" 2>/dev/null | wc -l | tr -d ' ')
      if (( results > 0 )); then
        echo "${session_dir}"
      fi
    fi
  done < <(find "${swarm_dir}" -maxdepth 2 -name "ledger.yaml" 2>/dev/null)
}

swarm_get_completed_tasks() {
  # Read all .result files, return task IDs that have Status: DONE
  local session_dir="$1"
  for result in "${session_dir}"/tasks/*.result; do
    [[ -f "${result}" ]] || continue
    if grep -q '^Status: DONE' "${result}"; then
      basename "${result}" .result
    fi
  done
}

# ── Model Routing ────────────────────────────────────────────────

swarm_classify_task() {
  # Classify a task file as simple/standard/complex based on keywords + file count.
  # Reads model_routing from agents.yaml for keyword lists.
  # Usage: MODEL=$(swarm_classify_task "/path/to/task-001.md")
  local task_file="$1"
  local registry="${HOME}/.claude/local-plugins/plugins/swarm/agents.yaml"

  local content
  content=$(cat "${task_file}" 2>/dev/null || echo "")
  local content_lower
  content_lower=$(echo "${content}" | tr '[:upper:]' '[:lower:]')

  # Count files to touch
  local file_count=0
  # Note: `grep -c || echo "0"` double-prints when grep matches 0 (grep prints
  # "0" AND exits 1). Use `|| true` to preserve grep's output only.
  file_count=$(echo "${content}" | sed -n '/^## Files to Touch/,/^##/p' | grep -c '^- ' 2>/dev/null || true)
  file_count="${file_count:-0}"

  # Check complex keywords first (highest priority)
  for kw in refactor architect design system migrate security optimize; do
    if echo "${content_lower}" | grep -qw "${kw}"; then
      echo "opus"
      return 0
    fi
  done

  # Check if file count pushes to complex
  if (( file_count > 5 )); then
    echo "opus"
    return 0
  fi

  # Check simple keywords
  local is_simple=false
  for kw in fix typo rename update change "add comment" simple small trivial; do
    if echo "${content_lower}" | grep -qw "${kw}"; then
      is_simple=true
      break
    fi
  done

  if [[ "${is_simple}" == true ]] && (( file_count <= 2 )); then
    echo "haiku"
    return 0
  fi

  # Default: standard
  echo "sonnet"
}

# ── Self-Corrective Loop ─────────────────────────────────────────

swarm_get_revision_count() {
  # Return the highest revision number for a task (0 if none).
  # Uses find to avoid zsh glob issues.
  local session_dir="$1"
  local task_id="$2"
  local max=0
  while IFS= read -r rev_file; do
    local num
    num=$(basename "${rev_file}" .md | sed "s/.*-rev//")
    if [[ "${num}" =~ ^[0-9]+$ ]] && (( num > max )); then
      max="${num}"
    fi
  done < <(find "${session_dir}/tasks" -name "${task_id}-rev*.md" -type f 2>/dev/null)
  echo "${max}"
}

swarm_check_result_status() {
  # Parse a .result file. Returns one of:
  #   DONE       — Status: DONE + Files Changed field present
  #   PARTIAL    — Status: PARTIAL (agent made progress but hit a blocker)
  #   NEEDS_HELP — Status: NEEDS_HELP (agent is uncertain)
  #   FAILED     — Status: FAILED (agent could not proceed)
  #   INCOMPLETE — Status: DONE but missing Files Changed
  #   MISSING    — result file does not exist
  #   MALFORMED  — no recognizable Status line
  local result_file="$1"
  if [[ ! -f "${result_file}" ]]; then
    echo "MISSING"
    return 0
  fi
  local status_line
  status_line=$(grep -im1 '^Status:' "${result_file}" 2>/dev/null || echo "")
  if [[ -z "${status_line}" ]]; then
    echo "MALFORMED"
    return 0
  fi
  # Order matters: check NEEDS_HELP before PARTIAL before DONE/FAILED
  # to avoid substring collisions.
  if echo "${status_line}" | grep -qi "NEEDS_HELP"; then
    echo "NEEDS_HELP"
  elif echo "${status_line}" | grep -qi "PARTIAL"; then
    echo "PARTIAL"
  elif echo "${status_line}" | grep -qi "FAILED"; then
    echo "FAILED"
  elif echo "${status_line}" | grep -qi "DONE"; then
    # Validate required fields for DONE
    if ! grep -iq '^Files Changed:' "${result_file}" 2>/dev/null; then
      echo "INCOMPLETE"
      return 0
    fi
    echo "DONE"
  else
    echo "MALFORMED"
  fi
}

swarm_get_acceptance_criteria() {
  # Extract acceptance criteria from a task file (handles indented bullets).
  # Uses flag-based parsing (awk range breaks on macOS when start matches end).
  local task_file="$1"
  [[ -f "${task_file}" ]] || return 0
  awk '
    /^## Acceptance Criteria/ { capture=1; next }
    /^## / && capture { capture=0 }
    capture && /^[[:space:]]*-/ { print }
  ' "${task_file}" 2>/dev/null
}

swarm_get_files_changed() {
  # Extract file paths from a .result file's "Files Changed:" section.
  # Parses "- path/to/file" lines, validates each file exists.
  # Non-existent files are emitted with a "[missing]" suffix on stderr.
  local result_file="$1"
  [[ -f "${result_file}" ]] || return 0
  local in_section=false
  while IFS= read -r line; do
    if [[ "${line}" =~ ^Files\ Changed: ]]; then
      in_section=true
      # Handle inline list: "Files Changed: [foo.py, bar.py]"
      local inline
      inline=$(echo "${line}" | sed 's/^Files Changed:[[:space:]]*//' | tr -d '[]' | tr ',' '\n')
      while IFS= read -r f; do
        f=$(echo "${f}" | xargs)  # trim whitespace
        if [[ -n "${f}" ]]; then
          if [[ ! -f "${f}" ]]; then
            echo "WARNING: file not found: ${f}" >&2
          fi
          echo "${f}"
        fi
      done <<< "${inline}"
      continue
    fi
    if [[ "${in_section}" == true ]]; then
      # Stop at next field (Summary:, Issues:, etc.) or section header (##)
      [[ "${line}" =~ ^(Summary|Issues|Status|##) ]] && break
      # Skip empty lines
      [[ -z "${line}" ]] && continue
      # Parse "- path/to/file" lines only (must start with dash)
      if [[ "${line}" =~ ^[[:space:]]*-[[:space:]] ]]; then
        local filepath
        filepath=$(echo "${line}" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/[[:space:]]*(.*//' | xargs)
        if [[ -n "${filepath}" ]]; then
          if [[ ! -f "${filepath}" ]]; then
            echo "WARNING: file not found: ${filepath}" >&2
          fi
          echo "${filepath}"
        fi
      fi
    fi
  done < "${result_file}"
}

swarm_write_revision_task() {
  # Create a revision task with FULL original context + specific issues.
  local session_dir="$1"
  local task_id="$2"
  local rev_num="$3"
  local issues="$4"
  local original_task="${session_dir}/tasks/${task_id}.md"
  local rev_file="${session_dir}/tasks/${task_id}-rev${rev_num}.md"

  if [[ ! -f "${original_task}" ]]; then
    echo "ERROR: Original task not found: ${original_task}" >&2
    return 1
  fi

  # Embed original task but STRIP the Instructions section to avoid
  # conflicting result paths (original says task-NNN.result, revision
  # needs task-NNN-revN.result).
  local original_content
  original_content=$(sed '/^## Instructions/,$d' "${original_task}")

  cat > "${rev_file}" << REVEOF
# Revision ${rev_num} for ${task_id}

## Original Task (Full Context)
${original_content}

## Previous Evaluation — Issues Found
${issues}

## Required Changes
Fix ALL issues listed above. Every acceptance criterion from the original task must pass.

## Instructions
Write your result to: ${session_dir}/tasks/${task_id}-rev${rev_num}.result
Format:
- Status: DONE | FAILED
- Files Changed:
  - [list each file on its own line]
- Summary: [what you fixed]
- Issues: [any remaining problems]
REVEOF

  echo "${rev_file}"
}

swarm_can_revise() {
  # Check if more revisions are allowed (max 2).
  local session_dir="$1"
  local task_id="$2"
  local count
  count=$(swarm_get_revision_count "${session_dir}" "${task_id}")
  (( count < 2 ))
}

swarm_next_revision_num() {
  # Return the next safe revision number (avoids overwrites).
  local session_dir="$1"
  local task_id="$2"
  local max
  max=$(swarm_get_revision_count "${session_dir}" "${task_id}")
  echo $(( max + 1 ))
}

swarm_record_revision_progress() {
  # Record criteria pass/fail for a revision round. Writes a sidecar file
  # that tracks convergence: are more criteria passing each round?
  # Usage: swarm_record_revision_progress "$session_dir" "task-001" 1 "3/5"
  local session_dir="$1"
  local task_id="$2"
  local rev_num="$3"
  local criteria_summary="$4"  # e.g. "3/5 passed" or "PASS:foo,bar FAIL:baz"
  local progress_file="${session_dir}/tasks/${task_id}.progress"
  echo "rev${rev_num}: ${criteria_summary} @ $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${progress_file}"
}

swarm_check_revision_convergence() {
  # Check if revisions are converging (more criteria passing) or cycling.
  # Returns: "converging", "stalled", or "no_data"
  local session_dir="$1"
  local task_id="$2"
  local progress_file="${session_dir}/tasks/${task_id}.progress"
  [[ -f "${progress_file}" ]] || { echo "no_data"; return 0; }
  local lines
  lines=$(wc -l < "${progress_file}" | tr -d ' ')
  if (( lines < 2 )); then
    echo "no_data"
    return 0
  fi
  # Compare last two entries — extract pass counts (assumes "N/M passed" format)
  local prev_pass last_pass
  prev_pass=$(tail -2 "${progress_file}" | head -1 | grep -o '[0-9]*/[0-9]*' | head -1 | cut -d/ -f1)
  last_pass=$(tail -1 "${progress_file}" | grep -o '[0-9]*/[0-9]*' | head -1 | cut -d/ -f1)
  if [[ -z "${prev_pass}" || -z "${last_pass}" ]]; then
    echo "no_data"
    return 0
  fi
  if (( last_pass > prev_pass )); then
    echo "converging"
  else
    echo "stalled"
  fi
}

# ── Conversation Protocol ────────────────────────────────────────
# AutoGen-style continuous conversations: agents can ask questions
# mid-task via .question files, orchestrator responds via .answer files.

swarm_poll_conversation() {
  # Poll for BOTH .result AND .question files. Returns which appeared first.
  # Usage: EVENT=$(swarm_poll_conversation "task-001.md" 300 5)
  # Returns: "result", "question", or "timeout"
  local task_file="$1"
  local timeout="${2:-300}"
  local interval="${3:-5}"
  local elapsed=0
  local question_file="${task_file%.md}.question"
  local result_file="${task_file%.md}.result"

  # Validate task file exists (skip for review files)
  if [[ "${task_file}" != */reviews/* ]] && [[ ! -f "${task_file}" ]]; then
    echo "ERROR: task file not found: ${task_file}" >&2
    return 1
  fi

  while (( elapsed < timeout )); do
    # Check result first (takes priority — agent finished)
    if swarm_check_result "${task_file}"; then
      echo "result"
      return 0
    fi
    # Check for question
    if [[ -f "${question_file}" ]] && [[ -s "${question_file}" ]]; then
      echo "question"
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
  echo "timeout"
  return 1
}

swarm_post_answer() {
  # Write answer to .answer file, clear .question, notify agent pane.
  # Usage: swarm_post_answer "task-001.md" "Use cursor-based pagination" "surface:42"
  local task_file="$1"
  local answer="$2"
  local pane_id="${3:-}"
  local answer_file="${task_file%.md}.answer"
  local question_file="${task_file%.md}.question"

  echo "${answer}" > "${answer_file}"
  rm -f "${question_file}"

  # Log to conversation thread
  swarm_append_thread "${task_file}" "orchestrator" "answer" "${answer}"

  # Notify agent in pane to check answer
  if [[ -n "${pane_id}" ]]; then
    swarm_pipe_prompt "${pane_id}" "Your question has been answered. Read ${answer_file} and continue your task."
  fi
}

swarm_append_thread() {
  # Append a turn to the conversation thread (JSONL format).
  # Usage: swarm_append_thread "task-001.md" "agent" "question" "What schema?"
  local task_file="$1"
  local from="$2"
  local msg_type="$3"
  local content="$4"
  local thread_file="${task_file%.md}.thread.jsonl"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Escape content for JSON (newlines, quotes, backslashes)
  local escaped
  escaped=$(printf '%s' "${content}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' ')

  echo "{\"ts\":\"${timestamp}\",\"from\":\"${from}\",\"type\":\"${msg_type}\",\"content\":\"${escaped}\"}" >> "${thread_file}"
}

swarm_read_thread() {
  # Read full conversation thread for a task.
  # Usage: THREAD=$(swarm_read_thread "task-001.md")
  local task_file="$1"
  local thread_file="${task_file%.md}.thread.jsonl"
  if [[ -f "${thread_file}" ]]; then
    cat "${thread_file}"
  else
    echo ""
  fi
}

# ── Cross-Wave Context Channel ───────────────────────────────────
# Agents post discoveries during execution; orchestrator propagates
# relevant ones to subsequent waves.

swarm_post_discovery() {
  # Record a discovery for cross-wave context sharing.
  # Usage: swarm_post_discovery "$SESSION_DIR" "Codex-1" "DB uses UUID primary keys"
  local session_dir="$1"
  local agent="$2"
  local discovery="$3"
  local channel="${session_dir}/context-updates.md"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "- [${timestamp}] **${agent}**: ${discovery}" >> "${channel}"
}

swarm_get_discoveries() {
  # Read accumulated discoveries for embedding in next wave's tasks.
  # Usage: DISCOVERIES=$(swarm_get_discoveries "$SESSION_DIR")
  local session_dir="$1"
  local channel="${session_dir}/context-updates.md"
  if [[ -f "${channel}" ]]; then
    cat "${channel}"
  else
    echo ""
  fi
}
