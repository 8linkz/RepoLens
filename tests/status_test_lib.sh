#!/usr/bin/env bash
# Copyright 2025-2026 Bootstrap Academy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Shared helpers for issue #121 status.json integration tests.

STATUS_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
# shellcheck disable=SC2034 # Shared mutable state for sourced status tests.
RUN_ID=""
RUN_PID=""

STATUS_TEST_TMPDIR="$(mktemp -d "$STATUS_TEST_ROOT/logs/status-test.XXXXXX")"
STATUS_TEST_RUN_IDS=()

status_cleanup() {
  if [[ -n "${RUN_PID:-}" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
    kill -TERM "-$RUN_PID" 2>/dev/null || kill -TERM "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
  fi

  rm -rf "$STATUS_TEST_TMPDIR"
  local id
  for id in "${STATUS_TEST_RUN_IDS[@]:-}"; do
    [[ -n "$id" ]] && rm -rf "$STATUS_TEST_ROOT/logs/$id"
  done
}

status_register_run_id() {
  local id="$1"
  [[ -n "$id" ]] || return 0
  STATUS_TEST_RUN_IDS+=("$id")
}

record_pass() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
}

record_fail() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  if [[ -n "$detail" ]]; then
    echo "  FAIL: $desc ($detail)"
  else
    echo "  FAIL: $desc"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "expected='$expected' actual='${actual:-<empty>}'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "needle='$needle' not found"
  fi
}

assert_jq() {
  local desc="$1" file="$2" filter="$3"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]] && jq -e "$filter" "$file" >/dev/null 2>&1; then
    record_pass "$desc"
  else
    record_fail "$desc" "file=$file filter=$filter"
  fi
}

assert_jq_arg() {
  local desc="$1" file="$2" arg_name="$3" arg_value="$4" filter="$5"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]] && jq -e --arg "$arg_name" "$arg_value" "$filter" "$file" >/dev/null 2>&1; then
    record_pass "$desc"
  else
    record_fail "$desc" "file=$file filter=$filter"
  fi
}

status_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: jq not available"
    echo ""
    echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
    exit 0
  fi
}

status_setup_project() {
  local project="$1"
  mkdir -p "$project"
  (
    cd "$project" || exit 1
    git init -q 2>/dev/null
    git config user.email test@example.com
    git config user.name Test
    printf '# test project\n' > README.md
    git add README.md
    git commit -q -m init 2>/dev/null
  ) || true
}

parse_run_id() {
  local output_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$output_file" 2>/dev/null | head -1 | awk '{print $3}'
}

wait_for_run_id() {
  local output_file="$1"
  local run_id=""
  for _ in {1..80}; do
    run_id="$(parse_run_id "$output_file")"
    if [[ -n "$run_id" ]]; then
      printf '%s\n' "$run_id"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_jq() {
  local file="$1" filter="$2" attempts="${3:-60}"
  for ((i = 0; i < attempts; i++)); do
    if [[ -f "$file" ]] && jq -e "$filter" "$file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_with_watchdog() {
  local pid="$1" seconds="$2" rc
  (
    sleep "$seconds"
    kill "$pid" 2>/dev/null || true
  ) &
  local watchdog_pid=$!
  wait "$pid"
  rc=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$rc"
}

terminate_run_group() {
  local pid="$1"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    wait_with_watchdog "$pid" 4 >/dev/null 2>&1 || true
  fi
}

status_finish() {
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit "$FAIL"
}
