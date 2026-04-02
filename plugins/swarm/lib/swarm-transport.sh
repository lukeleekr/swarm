#!/usr/bin/env bash
# swarm-transport.sh — Multiplexer abstraction + file protocol for swarm plugin
# Source this in the skill: source ~/.claude/local-plugins/plugins/swarm/lib/swarm-transport.sh

set -euo pipefail

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
session_id: ${session_id}
phase: init
plan_source: null
mux: ${mux}
agents: []
tasks_total: 0
tasks_done: 0
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

swarm_update_ledger_field() {
  local session_dir="$1"
  local field="$2"
  local value="$3"
  local ledger="${session_dir}/ledger.yaml"
  if [[ -f "${ledger}" ]]; then
    sed -i '' "s/^${field}: .*/${field}: ${value}/" "${ledger}"
    sed -i '' "s/^updated: .*/updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)/" "${ledger}"
  fi
}

# ── Agent Spawning ────────────────────────────────────────────────

swarm_spawn_agent() {
  local name="$1"
  local command="$2"
  local workdir="$3"
  local session_dir="$4"
  local mux
  mux="$(swarm_detect_mux)"

  local pane_id=""
  case "${mux}" in
    cmux)
      local output
      output=$(cmux new-surface 2>/dev/null || echo "")
      pane_id=$(echo "${output}" | grep -o 'surface:[0-9]*' | head -1)
      if [[ -n "${pane_id}" ]]; then
        cmux send --surface "${pane_id}" "cd ${workdir} && ${command}" >/dev/null 2>&1
        cmux send-key --surface "${pane_id}" Enter >/dev/null 2>&1
        cmux rename-tab --surface "${pane_id}" "${name}" >/dev/null 2>&1 || true
      fi
      ;;
    tmux)
      pane_id=$(tmux split-window -h -d -c "${workdir}" -P -F '#{pane_id}' "${command}" 2>/dev/null || echo "")
      ;;
    none)
      local log_file="${session_dir}/logs/${name}.log"
      nohup bash -c "cd '${workdir}' && ${command}" > "${log_file}" 2>&1 &
      pane_id="pid:$!"
      ;;
  esac

  echo "${pane_id}"
}

swarm_kill_agent() {
  local pane_id="$1"
  local mux
  mux="$(swarm_detect_mux)"

  case "${mux}" in
    cmux)
      if [[ "${pane_id}" == surface:* ]]; then
        cmux close-surface --surface "${pane_id}" 2>/dev/null || true
      fi
      ;;
    tmux)
      tmux kill-pane -t "${pane_id}" 2>/dev/null || true
      ;;
    none)
      if [[ "${pane_id}" == pid:* ]]; then
        local pid="${pane_id#pid:}"
        kill "${pid}" 2>/dev/null || true
      fi
      ;;
  esac
}

swarm_check_agent_alive() {
  local pane_id="$1"
  local mux
  mux="$(swarm_detect_mux)"

  case "${mux}" in
    cmux)
      cmux read-screen --surface "${pane_id}" --lines 1 >/dev/null 2>&1
      ;;
    tmux)
      tmux has-session -t "${pane_id}" 2>/dev/null
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
  local task_file="${session_dir}/tasks/task-$(printf '%03d' "${task_num}").md"
  echo "${content}" > "${task_file}"
  echo "${task_file}"
}

swarm_check_result() {
  local task_file="$1"
  local result_file="${task_file%.md}.result"
  [[ -f "${result_file}" ]] && [[ -s "${result_file}" ]]
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

swarm_poll_result() {
  local task_file="$1"
  local timeout="${2:-300}"
  local interval="${3:-5}"
  local elapsed=0

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
  local mux
  mux="$(swarm_detect_mux)"

  case "${mux}" in
    cmux)
      cmux send --surface "${pane_id}" "${prompt}" >/dev/null 2>&1
      cmux send-key --surface "${pane_id}" Enter >/dev/null 2>&1
      ;;
    tmux)
      tmux send-keys -t "${pane_id}" "${prompt}" Enter 2>/dev/null
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
  local mux
  mux="$(swarm_detect_mux)"
  if [[ "${mux}" == "cmux" ]]; then
    cmux set-status "role" "${role}" --icon "robot.fill" --color "#4CAF50" 2>/dev/null || true
  fi
}

swarm_set_progress() {
  local label="$1"
  local progress="$2"
  local mux
  mux="$(swarm_detect_mux)"
  if [[ "${mux}" == "cmux" ]]; then
    cmux set-progress "${progress}" --label "${label}" 2>/dev/null || true
  fi
}

swarm_log() {
  local level="${1:-info}"
  local message="$2"
  local mux
  mux="$(swarm_detect_mux)"
  if [[ "${mux}" == "cmux" ]]; then
    cmux log --level "${level}" "${message}" 2>/dev/null || true
  fi
}

# ── Cleanup ───────────────────────────────────────────────────────

swarm_cleanup() {
  local session_dir="$1"
  local ledger="${session_dir}/ledger.yaml"

  if [[ ! -f "${ledger}" ]]; then return 0; fi

  local pane_ids
  pane_ids=$(grep 'pane_id:' "${ledger}" | awk '{print $2}' 2>/dev/null || echo "")
  for pane_id in ${pane_ids}; do
    swarm_kill_agent "${pane_id}"
  done

  swarm_update_ledger_field "${session_dir}" "phase" "done"
  swarm_set_progress "Done" "1.0"
  swarm_log "success" "Swarm session complete"
}

# ── Stale Session Detection ──────────────────────────────────────

swarm_find_stale_sessions() {
  local project_dir="${1:-.}"
  local stale=()
  for ledger in "${project_dir}"/.swarm/*/ledger.yaml; do
    [[ -f "${ledger}" ]] || continue
    local phase
    phase=$(grep '^phase:' "${ledger}" | awk '{print $2}')
    if [[ "${phase}" != "done" ]]; then
      stale+=("$(dirname "${ledger}")")
    fi
  done
  printf '%s\n' "${stale[@]}"
}

# ── Gitignore ─────────────────────────────────────────────────────

swarm_ensure_gitignore() {
  local project_dir="${1:-.}"
  if [[ -f "${project_dir}/.gitignore" ]]; then
    if ! grep -q '.swarm/' "${project_dir}/.gitignore" 2>/dev/null; then
      echo '.swarm/' >> "${project_dir}/.gitignore"
    fi
  fi
}
