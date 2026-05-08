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

# Integration test for issue #120: per-lens heartbeat files are written for
# concurrently running workers in --parallel mode and are removed after clean
# completion.
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

assert_heartbeat_json() {
  local lens_id="$1" file="$2"

  TOTAL=$((TOTAL + 1))
  if jq -e \
    --arg run "$RUN_ID" \
    '.run_id == $run' "$file" >/dev/null 2>&1 \
    && jq -e \
      --arg lens "$lens_id" \
      '.domain == "i18n" and .lens_id == $lens and .iteration == 1 and .state == "running" and (.pid | type == "number")' "$file" >/dev/null 2>&1; then
    record_pass "Parallel heartbeat JSON fields are correct for $lens_id"
  else
    record_fail "Parallel heartbeat JSON fields are correct for $lens_id" "file=$file"
  fi
}

echo "=== per-lens heartbeat works in parallel mode ==="

if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: jq not available"
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit 0
fi

PROJECT="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
OUT_FILE="$TMPDIR/run.log"
STATE_FILE="$TMPDIR/fake-codex-count"
mkdir -p "$FAKE_BIN"
setup_project "$PROJECT"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
state="${REPOLENS_TEST_STATE:?state path required}"
lock="${state}.lock"
while ! mkdir "$lock" 2>/dev/null; do
  sleep 0.05
done
count=0
[[ -f "$state" ]] && count="$(cat "$state")"
count=$((count + 1))
printf '%s\n' "$count" > "$state"
rmdir "$lock"

# The first two invocations correspond to the two i18n lenses started under
# --parallel --max-parallel 2. Keep both silent long enough to observe two
# active heartbeat files, then let later DONE-streak iterations finish fast.
if (( count <= 2 )); then
  sleep 6
fi

echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

env \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_TEST_STATE="$STATE_FILE" \
  REPOLENS_HEARTBEAT_INTERVAL=1 \
  REPOLENS_AGENT_TIMEOUT=20 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT" \
    --agent codex \
    --domain i18n \
    --mode audit \
    --local \
    --yes \
    --parallel \
    --max-parallel 2 \
    >"$OUT_FILE" 2>&1 &
RUN_PID=$!

if RUN_ID="$(wait_for_run_id "$OUT_FILE")"; then
  TOTAL=$((TOTAL + 1))
  record_pass "Parallel run id is logged"
else
  TOTAL=$((TOTAL + 1))
  record_fail "Parallel run id is logged" "startup log did not contain run id"
fi

HEARTBEAT_DIR="$SCRIPT_DIR/logs/$RUN_ID/.heartbeat"
STRINGS_FILE="$HEARTBEAT_DIR/i18n__i18n-strings.json"
FORMATTING_FILE="$HEARTBEAT_DIR/i18n__i18n-formatting.json"

TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" && -d "$HEARTBEAT_DIR" ]]; then
  record_pass "Run-level .heartbeat directory exists in parallel mode"
else
  record_fail "Run-level .heartbeat directory exists in parallel mode" "missing $HEARTBEAT_DIR"
fi

TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" ]] && wait_for_file "$STRINGS_FILE"; then
  record_pass "Parallel heartbeat exists for i18n-strings while active"
else
  record_fail "Parallel heartbeat exists for i18n-strings while active" "missing $STRINGS_FILE"
fi

TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" ]] && wait_for_file "$FORMATTING_FILE"; then
  record_pass "Parallel heartbeat exists for i18n-formatting while active"
else
  record_fail "Parallel heartbeat exists for i18n-formatting while active" "missing $FORMATTING_FILE"
fi

if [[ -f "$STRINGS_FILE" ]]; then
  assert_heartbeat_json "i18n-strings" "$STRINGS_FILE"
else
  TOTAL=$((TOTAL + 1))
  record_fail "Parallel heartbeat JSON fields are correct for i18n-strings" "heartbeat file missing"
fi

if [[ -f "$FORMATTING_FILE" ]]; then
  assert_heartbeat_json "i18n-formatting" "$FORMATTING_FILE"
else
  TOTAL=$((TOTAL + 1))
  record_fail "Parallel heartbeat JSON fields are correct for i18n-formatting" "heartbeat file missing"
fi

wait_with_watchdog "$RUN_PID" 12
run_rc=$?
RUN_PID=""
assert_eq "Parallel RepoLens run exits cleanly after DONE streaks" "0" "$run_rc"

TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" && ! -e "$STRINGS_FILE" && ! -e "$FORMATTING_FILE" ]]; then
  record_pass "Parallel heartbeat files are removed after clean completion"
else
  record_fail "Parallel heartbeat files are removed after clean completion" "remaining files under $HEARTBEAT_DIR"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
