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

# Integration test for issue #120: an active lens writes a machine-readable
# heartbeat file while the agent is still running and producing no output.
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
    kill -TERM "-$RUN_PID" 2>/dev/null || kill "$RUN_PID" 2>/dev/null || true
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

assert_matches() {
  local desc="$1" regex="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" =~ $regex ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "actual='${actual:-<empty>}' pattern='$regex'"
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
  for _ in {1..30}; do
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

echo "=== per-lens heartbeat is written while lens is active ==="

if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: jq not available"
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit 0
fi

PROJECT="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
OUT_FILE="$TMPDIR/run.log"
mkdir -p "$FAKE_BIN"
setup_project "$PROJECT"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
# Stay silent while the lens is active so the heartbeat is the only
# machine-readable liveness signal. This should still be running when the
# test terminates RepoLens to verify stale heartbeat behavior.
trap 'exit 143' TERM INT
sleep 20
echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

setsid env \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_HEARTBEAT_INTERVAL=0 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=1 \
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

HEARTBEAT_FILE="$SCRIPT_DIR/logs/$RUN_ID/.heartbeat/i18n__i18n-strings.json"

TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" ]] && wait_for_file "$HEARTBEAT_FILE"; then
  record_pass "Heartbeat file appears while fake agent is still silent"
else
  record_fail "Heartbeat file appears while fake agent is still silent" "missing $HEARTBEAT_FILE"
fi

if [[ -f "$HEARTBEAT_FILE" ]]; then
  TOTAL=$((TOTAL + 1))
  if jq -e . "$HEARTBEAT_FILE" >/dev/null 2>&1; then
    record_pass "Heartbeat file is valid JSON"
  else
    record_fail "Heartbeat file is valid JSON"
  fi

  assert_eq "Heartbeat run_id matches the active run" "$RUN_ID" "$(jq -r '.run_id' "$HEARTBEAT_FILE")"
  assert_eq "Heartbeat domain is i18n" "i18n" "$(jq -r '.domain' "$HEARTBEAT_FILE")"
  assert_eq "Heartbeat lens_id is i18n-strings" "i18n-strings" "$(jq -r '.lens_id' "$HEARTBEAT_FILE")"
  assert_matches "Heartbeat pid is numeric" '^[0-9]+$' "$(jq -r '.pid' "$HEARTBEAT_FILE")"
  assert_eq "Heartbeat iteration reflects the active first iteration" "1" "$(jq -r '.iteration' "$HEARTBEAT_FILE")"
  assert_eq "Heartbeat state is running" "running" "$(jq -r '.state' "$HEARTBEAT_FILE")"
  assert_matches "Heartbeat started_at is an ISO-like UTC timestamp" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$(jq -r '.started_at' "$HEARTBEAT_FILE")"

  first_heartbeat="$(jq -r '.last_heartbeat_at' "$HEARTBEAT_FILE")"
  sleep 2
  second_heartbeat="$(jq -r '.last_heartbeat_at' "$HEARTBEAT_FILE" 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if [[ -n "$first_heartbeat" && -n "$second_heartbeat" && "$first_heartbeat" != "$second_heartbeat" ]]; then
    record_pass "last_heartbeat_at advances on the configured interval"
  else
    record_fail "last_heartbeat_at advances on the configured interval" "first='${first_heartbeat:-<empty>}' second='${second_heartbeat:-<empty>}'"
  fi
else
  for desc in \
    "Heartbeat file is valid JSON" \
    "Heartbeat run_id matches the active run" \
    "Heartbeat domain is i18n" \
    "Heartbeat lens_id is i18n-strings" \
    "Heartbeat pid is numeric" \
    "Heartbeat iteration reflects the active first iteration" \
    "Heartbeat state is running" \
    "Heartbeat started_at is an ISO-like UTC timestamp" \
    "last_heartbeat_at advances on the configured interval"
  do
    TOTAL=$((TOTAL + 1))
    record_fail "$desc" "heartbeat file missing"
  done
fi

if [[ -n "${RUN_PID:-}" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
  kill -TERM "-$RUN_PID" 2>/dev/null || kill -TERM "$RUN_PID" 2>/dev/null || true
fi
wait_with_watchdog "$RUN_PID" 4
run_rc=$?
RUN_PID=""

TOTAL=$((TOTAL + 1))
if [[ "$run_rc" != "0" ]]; then
  record_pass "RepoLens run is interrupted before fake DONE"
else
  record_fail "RepoLens run is interrupted before fake DONE" "run exited cleanly before signal"
fi

TOTAL=$((TOTAL + 1))
if [[ -f "$HEARTBEAT_FILE" ]]; then
  record_pass "Heartbeat file remains after abnormal termination"
else
  record_fail "Heartbeat file remains after abnormal termination" "missing $HEARTBEAT_FILE"
fi

stale_heartbeat_after_exit="$(jq -r '.last_heartbeat_at' "$HEARTBEAT_FILE" 2>/dev/null || true)"
sleep 1.5
stale_heartbeat_after_stop="$(jq -r '.last_heartbeat_at' "$HEARTBEAT_FILE" 2>/dev/null || true)"
TOTAL=$((TOTAL + 1))
if [[ -n "$stale_heartbeat_after_exit" && "$stale_heartbeat_after_exit" == "$stale_heartbeat_after_stop" ]]; then
  record_pass "Stale heartbeat stops advancing after owner exits"
else
  record_fail "Stale heartbeat stops advancing after owner exits" "after_exit='${stale_heartbeat_after_exit:-<empty>}' after_wait='${stale_heartbeat_after_stop:-<empty>}'"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
