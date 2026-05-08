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

# Integration test for issue #120: REPOLENS_LENS_HEARTBEAT_INTERVAL=0 disables
# per-lens heartbeat files even while a lens is actively running.
#
# No real AI model is invoked. The test runs repolens.sh through its public
# CLI with a fake `codex` binary on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
RUN_ID=""
RUN_PID=""

# shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap.
cleanup() {
  if [[ -n "${RUN_PID:-}" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
    kill "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
  [[ -n "$RUN_ID" ]] && rm -rf "$SCRIPT_DIR/logs/$RUN_ID"
}
trap cleanup EXIT

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

wait_for_run_id() {
  local output_file="$1"
  local run_id=""
  for _ in {1..50}; do
    run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$output_file" 2>/dev/null | head -1 | awk '{print $3}')"
    if [[ -n "$run_id" ]]; then
      printf '%s\n' "$run_id"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_file() {
  local file="$1"
  for _ in {1..50}; do
    [[ -f "$file" ]] && return 0
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

setup_project() {
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

echo "=== per-lens heartbeat files can be disabled ==="

PROJECT="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
OUT_FILE="$TMPDIR/run.log"
STARTED_FILE="$TMPDIR/fake-agent-started"
mkdir -p "$FAKE_BIN"
setup_project "$PROJECT"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'started\n' > "${REPOLENS_TEST_STARTED:?started marker required}"
sleep 4
echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

env \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_TEST_STARTED="$STARTED_FILE" \
  REPOLENS_HEARTBEAT_INTERVAL=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=0 \
  REPOLENS_AGENT_TIMEOUT=20 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT" \
    --agent codex \
    --focus i18n-strings \
    --mode audit \
    --local \
    --yes \
    --max-issues 1 \
    >"$OUT_FILE" 2>&1 &
RUN_PID=$!

if RUN_ID="$(wait_for_run_id "$OUT_FILE")"; then
  TOTAL=$((TOTAL + 1))
  record_pass "Run id is logged"
else
  TOTAL=$((TOTAL + 1))
  record_fail "Run id is logged" "startup log did not contain run id"
fi

if wait_for_file "$STARTED_FILE"; then
  TOTAL=$((TOTAL + 1))
  record_pass "Fake agent has started"
else
  TOTAL=$((TOTAL + 1))
  record_fail "Fake agent has started" "marker missing"
fi

HEARTBEAT_DIR="$SCRIPT_DIR/logs/$RUN_ID/.heartbeat"
HEARTBEAT_FILE="$HEARTBEAT_DIR/i18n__i18n-strings.json"

sleep 1.5

TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" && -d "$HEARTBEAT_DIR" ]]; then
  record_pass "Run-level .heartbeat directory still exists"
else
  record_fail "Run-level .heartbeat directory still exists" "missing $HEARTBEAT_DIR"
fi

TOTAL=$((TOTAL + 1))
if [[ -n "${RUN_PID:-}" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
  record_pass "RepoLens run is still active during disabled-heartbeat check"
else
  record_fail "RepoLens run is still active during disabled-heartbeat check"
fi

TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" && ! -e "$HEARTBEAT_FILE" ]]; then
  record_pass "Per-lens heartbeat file is not written while disabled"
else
  record_fail "Per-lens heartbeat file is not written while disabled" "unexpected file at $HEARTBEAT_FILE"
fi

wait_with_watchdog "$RUN_PID" 8
run_rc=$?
RUN_PID=""
assert_eq "RepoLens run exits cleanly after fake DONE" "0" "$run_rc"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
