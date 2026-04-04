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
      > "${tmp}" && mv "${tmp}" "${ledger}" || rm -f "${tmp}"
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
      sed "s/^agents: \[\]/agents:/" "${ledger}" > "${tmp}" && mv "${tmp}" "${ledger}" || rm -f "${tmp}"
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
    sed "s/^updated: .*/updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)/" "${ledger}" > "${tmp}" && mv "${tmp}" "${ledger}" || rm -f "${tmp}"
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
  local mux
  mux="$(swarm_detect_mux)"

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
      # tmux -c sets workdir; command passed as separate arg (no string interpolation)
      if [[ -n "${split_from}" ]]; then
        pane_id=$(tmux split-window ${tmux_split_flag} -t "${split_from}" -d -c "${workdir}" -P -F '#{pane_id}' -- "${command}" 2>/dev/null || echo "")
      else
        pane_id=$(tmux split-window ${tmux_split_flag} -d -c "${workdir}" -P -F '#{pane_id}' -- "${command}" 2>/dev/null || echo "")
      fi
      ;;
    none)
      local log_file="${session_dir}/logs/${name}.log"
      # Use exec "$@" to avoid eval; command is word-split intentionally (simple CLI invocations)
      nohup bash -c 'cd "$1" && shift && exec "$@"' _ "${workdir}" ${command} > "${log_file}" 2>&1 &
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
  local mux
  mux="$(swarm_detect_mux)"

  [[ "${mux}" == "none" ]] && return 0  # headless: always ready

  local elapsed=0
  while (( elapsed < timeout )); do
    local screen
    screen=$(cmux read-screen --surface "${pane_id}" --lines 10 2>/dev/null || echo "")

    # Detect trust/folder prompts and auto-accept by pressing Enter
    if echo "${screen}" | grep -qiE 'trust.*(folder|directory|contents)|Do you trust'; then
      cmux send-key --surface "${pane_id}" Enter 2>/dev/null || true
      sleep 3
      elapsed=$((elapsed + 3))
      continue
    fi

    # Agent ready patterns:
    # Codex: ">" or "›" at line start (input prompt)
    # Claude: "❯" or ">" at line start
    # Shell: "$" or "%" at end of line
    if echo "${screen}" | grep -qE '(^[>❯›] |[$%] *$)'; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

swarm_kill_agent() {
  local pane_id="$1"
  local mux
  mux="$(swarm_detect_mux)"

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
  local mux
  mux="$(swarm_detect_mux)"

  case "${mux}" in
    cmux)
      cmux read-screen --surface "${pane_id}" --lines 1 >/dev/null 2>&1
      ;;
    tmux)
      tmux display-message -p -t "${pane_id}" '' 2>/dev/null
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
  if [[ -f "${project_dir}/.gitignore" ]]; then
    if ! grep -q '.swarm/' "${project_dir}/.gitignore" 2>/dev/null; then
      echo '.swarm/' >> "${project_dir}/.gitignore"
    fi
  fi
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
  file_count=$(echo "${content}" | sed -n '/^## Files to Touch/,/^##/p' | grep -c '^- ' 2>/dev/null || echo "0")

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
  # Parse a .result file. Returns: DONE, FAILED, MISSING, MALFORMED, or INCOMPLETE.
  # DONE requires Status: DONE + Files Changed field present.
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
  if echo "${status_line}" | grep -qi "DONE"; then
    # Validate required fields for DONE
    if ! grep -iq '^Files Changed:' "${result_file}" 2>/dev/null; then
      echo "INCOMPLETE"
      return 0
    fi
    echo "DONE"
  elif echo "${status_line}" | grep -qi "FAILED"; then
    echo "FAILED"
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
      echo "${inline}" | while IFS= read -r f; do
        f=$(echo "${f}" | xargs)  # trim whitespace
        if [[ -n "${f}" ]]; then
          if [[ ! -f "${f}" ]]; then
            echo "WARNING: file not found: ${f}" >&2
          fi
          echo "${f}"
        fi
      done
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
