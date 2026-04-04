#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/plugins/swarm/lib/swarm-transport.sh"

failures=0

assert_success() {
  local description="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "${description}"
  else
    printf 'FAIL: %s\n' "${description}" >&2
    failures=$((failures + 1))
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "${haystack}" == *"${needle}"* ]]
}

make_fake_mv_dir() {
  local fake_bin="$1"
  mkdir -p "${fake_bin}"
  cat > "${fake_bin}/mv" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${fake_bin}/mv"
}

test_swarm_write_task_requires_tasks_dir() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local stderr_file="${tmp_dir}/stderr.log"
  local status=0

  if swarm_write_task "${tmp_dir}/missing-session" 1 'payload' > /dev/null 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi

  local stderr_output=''
  stderr_output="$(cat "${stderr_file}")"
  rm -rf "${tmp_dir}"

  [[ ${status} -ne 0 ]] && assert_contains "${stderr_output}" 'ERROR: tasks dir missing:'
}

test_swarm_poll_result_requires_task_file() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local missing_task="${tmp_dir}/tasks/task-001.md"
  local stderr_file="${tmp_dir}/stderr.log"
  local status=0

  if swarm_poll_result "${missing_task}" 0 1 > /dev/null 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi

  local stderr_output=''
  stderr_output="$(cat "${stderr_file}")"
  rm -rf "${tmp_dir}"

  [[ ${status} -ne 0 ]] && assert_contains "${stderr_output}" 'ERROR: task file not found:'
}

test_swarm_update_ledger_field_propagates_mv_failure() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  mkdir -p "${tmp_dir}/session"
  cat > "${tmp_dir}/session/ledger.yaml" <<'EOF'
phase: init
updated: old
EOF

  local fake_bin="${tmp_dir}/fake-bin"
  make_fake_mv_dir "${fake_bin}"
  local status=0

  if PATH="${fake_bin}:${PATH}" swarm_update_ledger_field "${tmp_dir}/session" 'phase' 'done'; then
    status=0
  else
    status=$?
  fi

  rm -rf "${tmp_dir}"
  [[ ${status} -ne 0 ]]
}

test_swarm_register_agent_propagates_mv_failure_on_agents_list_update() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  mkdir -p "${tmp_dir}/session"
  cat > "${tmp_dir}/session/ledger.yaml" <<'EOF'
updated: old
agents: []
EOF

  local fake_bin="${tmp_dir}/fake-bin"
  make_fake_mv_dir "${fake_bin}"
  local status=0

  if PATH="${fake_bin}:${PATH}" swarm_register_agent "${tmp_dir}/session" 'alpha' 'pane-1' 'worker'; then
    status=0
  else
    status=$?
  fi

  rm -rf "${tmp_dir}"
  [[ ${status} -ne 0 ]]
}

test_swarm_register_agent_propagates_mv_failure_on_updated_field_write() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  mkdir -p "${tmp_dir}/session"
  cat > "${tmp_dir}/session/ledger.yaml" <<'EOF'
updated: old
agents:
  - name: 'existing'
    pane_id: pane-0
    role: 'worker'
    status: idle
EOF

  local fake_bin="${tmp_dir}/fake-bin"
  make_fake_mv_dir "${fake_bin}"
  local status=0

  if PATH="${fake_bin}:${PATH}" swarm_register_agent "${tmp_dir}/session" 'alpha' 'pane-1' 'worker'; then
    status=0
  else
    status=$?
  fi

  rm -rf "${tmp_dir}"
  [[ ${status} -ne 0 ]]
}

assert_success 'swarm_write_task rejects missing tasks directory' test_swarm_write_task_requires_tasks_dir
assert_success 'swarm_poll_result rejects missing task file' test_swarm_poll_result_requires_task_file
assert_success 'swarm_update_ledger_field propagates mv failures' test_swarm_update_ledger_field_propagates_mv_failure
assert_success 'swarm_register_agent propagates mv failure when converting empty agents list' test_swarm_register_agent_propagates_mv_failure_on_agents_list_update
assert_success 'swarm_register_agent propagates mv failure when updating timestamp' test_swarm_register_agent_propagates_mv_failure_on_updated_field_write

if [[ ${failures} -ne 0 ]]; then
  exit 1
fi
