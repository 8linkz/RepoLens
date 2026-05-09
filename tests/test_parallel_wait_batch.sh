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

# Tests for issue #142: wait_batch_complete waits on a batch-local
# .completed barrier without touching the run-level child tracking arrays.
#
# No AI models are invoked. Tests source lib/parallel.sh directly and use
# synthetic sleep/touch producers.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/parallel.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$(mktemp -d)"
BG_PIDS=()

# shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap.
cleanup() {
  local pid
  for pid in "${BG_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
  fi
}

assert_lt() {
  local desc="$1" bound="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if (( actual < bound )); then
    PASS=$((PASS + 1))
    echo "  PASS: $desc ($actual < $bound)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (actual=$actual, expected < $bound)"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (missing '$needle' in output)"
    echo "  ---- haystack ----"
    printf '%s\n' "$haystack" | sed 's/^/    /'
    echo "  ------------------"
  fi
}

assert_matches() {
  local desc="$1" regex="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" =~ $regex ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (missing pattern '$regex')"
    echo "  ---- haystack ----"
    printf '%s\n' "$haystack" | sed 's/^/    /'
    echo "  ------------------"
  fi
}

fresh_barrier_dir() {
  mktemp -d -p "$TMPROOT" barrier.XXXXXX
}

echo "=== parallel.sh wait_batch_complete barrier (issue #142) ==="

wait_batch_src="$(declare -f wait_batch_complete 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# 1. Public primitive is declared with the documented timeout defaults.
# ---------------------------------------------------------------------------
assert_contains "wait_batch_complete function is declared" \
                "wait_batch_complete" "$wait_batch_src"
assert_contains "Default timeout reads BATCH_WAIT_TIMEOUT with 7200s fallback" \
                'BATCH_WAIT_TIMEOUT:-7200' "$wait_batch_src"
assert_contains "Default poll interval reads BATCH_POLL_INTERVAL with 5s fallback" \
                'BATCH_POLL_INTERVAL:-5' "$wait_batch_src"

# ---------------------------------------------------------------------------
# 2. Slow producer success path: the function blocks until .completed appears,
#    returns 0 within the caller's timeout, and logs path plus elapsed time.
# ---------------------------------------------------------------------------
barrier_dir="$(fresh_barrier_dir)"
(
  sleep 7
  touch "$barrier_dir/.completed"
) &
BG_PIDS+=("$!")

start="$(date +%s)"
success_output="$(BATCH_POLL_INTERVAL=1 wait_batch_complete "$barrier_dir" 15 2>&1)"
success_rc=$?
finish="$(date +%s)"
success_elapsed=$((finish - start))

assert_eq "Slow producer: wait_batch_complete returns 0" "0" "$success_rc"
assert_lt "Slow producer: returns within 15s timeout" 15 "$success_elapsed"
assert_contains "Slow producer: logs the barrier directory" "$barrier_dir" "$success_output"
assert_contains "Slow producer: entry log includes elapsed=0s" "elapsed=0s" "$success_output"
assert_matches "Slow producer: success log uses completion wording" \
               "([Cc]ompleted|[Ss]uccess)" "$success_output"

# ---------------------------------------------------------------------------
# 3. Timeout path: an empty barrier dir returns 1, logs a warning, and the
#    positional timeout overrides BATCH_WAIT_TIMEOUT for that call.
# ---------------------------------------------------------------------------
timeout_dir="$(fresh_barrier_dir)"
start="$(date +%s)"
timeout_output="$(BATCH_WAIT_TIMEOUT=6 BATCH_POLL_INTERVAL=1 wait_batch_complete "$timeout_dir" 2 2>&1)"
timeout_rc=$?
finish="$(date +%s)"
timeout_elapsed=$((finish - start))

assert_eq "Timeout: wait_batch_complete returns 1" "1" "$timeout_rc"
assert_lt "Timeout: positional 2s timeout overrides BATCH_WAIT_TIMEOUT=6" 5 "$timeout_elapsed"
assert_contains "Timeout: logs the barrier directory" "$timeout_dir" "$timeout_output"
assert_matches "Timeout: warning uses timeout wording" "[Tt]imeout" "$timeout_output"
assert_contains "Timeout: warning includes elapsed seconds" "elapsed=" "$timeout_output"

# ---------------------------------------------------------------------------
# 4. Environment timeout: with no positional override, BATCH_WAIT_TIMEOUT
#    controls the deadline.
# ---------------------------------------------------------------------------
env_timeout_dir="$(fresh_barrier_dir)"
start="$(date +%s)"
env_timeout_output="$(BATCH_WAIT_TIMEOUT=2 BATCH_POLL_INTERVAL=1 wait_batch_complete "$env_timeout_dir" 2>&1)"
env_timeout_rc=$?
finish="$(date +%s)"
env_timeout_elapsed=$((finish - start))

assert_eq "Env timeout: wait_batch_complete returns 1" "1" "$env_timeout_rc"
assert_lt "Env timeout: BATCH_WAIT_TIMEOUT=2 is honored" 5 "$env_timeout_elapsed"
assert_contains "Env timeout: log includes env timeout seconds" "timeout=2s" "$env_timeout_output"

# ---------------------------------------------------------------------------
# 5. Poll interval: with BATCH_POLL_INTERVAL=1, completion is detected shortly
#    after the producer touches .completed.
# ---------------------------------------------------------------------------
poll_dir="$(fresh_barrier_dir)"
touch_time_file="$poll_dir/touched-at"
(
  sleep 2
  date +%s > "$touch_time_file"
  touch "$poll_dir/.completed"
) &
BG_PIDS+=("$!")

poll_output="$(BATCH_POLL_INTERVAL=1 wait_batch_complete "$poll_dir" 10 2>&1)"
poll_rc=$?
poll_finish="$(date +%s)"
touch_time="$(cat "$touch_time_file" 2>/dev/null || printf '0')"
if [[ "$touch_time" =~ ^[0-9]+$ && "$touch_time" -gt 0 ]]; then
  poll_lag=$((poll_finish - touch_time))
else
  poll_lag=999
fi

assert_eq "Poll interval: wait_batch_complete returns 0" "0" "$poll_rc"
assert_lt "Poll interval: BATCH_POLL_INTERVAL=1 detects within 3s of touch" \
          3 "$poll_lag"
assert_contains "Poll interval: logs the barrier directory" "$poll_dir" "$poll_output"

# ---------------------------------------------------------------------------
# 6. The helper is independent of wait_all state. It must not reap, clear, or
#    otherwise mutate the run-level child tracking arrays.
# ---------------------------------------------------------------------------
state_dir="$(fresh_barrier_dir)"
touch "$state_dir/.completed"
_REPOLENS_CHILD_PIDS=("11111" "22222")
_REPOLENS_CHILD_LENS_IDS=("round/a" "round/b")
_REPOLENS_CHILD_STARTED_AT=("10" "20")

state_output="$(wait_batch_complete "$state_dir" 3 2>&1)"
state_rc=$?

assert_eq "Child state: precompleted barrier returns 0" "0" "$state_rc"
assert_eq "Child state: PIDs remain unchanged" \
          "11111 22222" "${_REPOLENS_CHILD_PIDS[*]}"
assert_eq "Child state: lens ids remain unchanged" \
          "round/a round/b" "${_REPOLENS_CHILD_LENS_IDS[*]}"
assert_eq "Child state: start times remain unchanged" \
          "10 20" "${_REPOLENS_CHILD_STARTED_AT[*]}"
assert_contains "Child state: success log includes elapsed seconds" "elapsed=" "$state_output"

# ---------------------------------------------------------------------------
# 7. Invalid numeric inputs are rejected before arithmetic and fall back to
#    documented defaults with clear warnings.
# ---------------------------------------------------------------------------
invalid_dir="$(fresh_barrier_dir)"
touch "$invalid_dir/.completed"

invalid_env_timeout_output="$(BATCH_WAIT_TIMEOUT=bogus wait_batch_complete "$invalid_dir" 2>&1)"
invalid_env_timeout_rc=$?
invalid_arg_timeout_output="$(wait_batch_complete "$invalid_dir" bogus 2>&1)"
invalid_arg_timeout_rc=$?
invalid_poll_output="$(BATCH_POLL_INTERVAL=bogus wait_batch_complete "$invalid_dir" 3 2>&1)"
invalid_poll_rc=$?
zero_poll_output="$(BATCH_POLL_INTERVAL=0 wait_batch_complete "$invalid_dir" 3 2>&1)"
zero_poll_rc=$?

assert_eq "Invalid env timeout: completed barrier still returns 0" "0" "$invalid_env_timeout_rc"
assert_contains "Invalid env timeout: warns with BATCH_WAIT_TIMEOUT name" \
                "Invalid BATCH_WAIT_TIMEOUT='bogus'" "$invalid_env_timeout_output"
assert_eq "Invalid positional timeout: completed barrier still returns 0" "0" "$invalid_arg_timeout_rc"
assert_contains "Invalid positional timeout: warns with argument name" \
                "Invalid timeout_seconds='bogus'" "$invalid_arg_timeout_output"
assert_eq "Invalid poll interval: completed barrier still returns 0" "0" "$invalid_poll_rc"
assert_contains "Invalid poll interval: warns about non-numeric value" \
                "Invalid BATCH_POLL_INTERVAL='bogus'" "$invalid_poll_output"
assert_eq "Zero poll interval: completed barrier still returns 0" "0" "$zero_poll_rc"
assert_contains "Zero poll interval: warns about zero value" \
                "Invalid BATCH_POLL_INTERVAL='0'" "$zero_poll_output"

# ---------------------------------------------------------------------------
# 8. Empty barrier_dir is a caller error. It must fail immediately instead of
#    accidentally observing /.completed.
# ---------------------------------------------------------------------------
start="$(date +%s)"
empty_output="$(wait_batch_complete "" 2 2>&1)"
empty_rc=$?
finish="$(date +%s)"
empty_elapsed=$((finish - start))

assert_eq "Empty barrier: wait_batch_complete returns 1" "1" "$empty_rc"
assert_lt "Empty barrier: fails immediately" 2 "$empty_elapsed"
assert_matches "Empty barrier: warning mentions barrier input" \
               "[Bb]arrier" "$empty_output"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
