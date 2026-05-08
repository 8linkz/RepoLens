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

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/tests/status_test_lib.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/status.sh"
trap status_cleanup EXIT

echo "=== stale heartbeat clean completion remains silent ==="
status_require_jq

RUN_ID="stale-clean-completion"
LOG_BASE="$STATUS_TEST_TMPDIR/$RUN_ID"
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
STATE_FILE="$HEARTBEAT_DIR/security__xss.state"
AGE_FILE="$HEARTBEAT_DIR/security__xss.state-age"
LOG_FILE="$LOG_BASE/$RUN_ID.log"
mkdir -p "$HEARTBEAT_DIR"
init_logging "$RUN_ID" "$LOG_BASE"
: > "$LOG_FILE"
printf 'error\n' > "$STATE_FILE"
printf '650\n' > "$AGE_FILE"

check_stale_heartbeats "$RUN_ID" "$LOG_BASE" "$HEARTBEAT_DIR" 120 600

log_contents="$(cat "$LOG_FILE")"
assert_eq "Clean completion produces no stale warning" "0" "$(grep -Ec '\[WARN\].*heartbeat stale' "$LOG_FILE" 2>/dev/null || true)"
assert_eq "Clean completion produces no stale error" "0" "$(grep -Ec '\[ERROR\].*heartbeat silent' "$LOG_FILE" 2>/dev/null || true)"
assert_eq "Clean completion produces no recovery" "0" "$(grep -Ec '\[INFO\].*heartbeat recovered' "$LOG_FILE" 2>/dev/null || true)"
assert_eq "Clean completion leaves log empty" "" "$log_contents"

TOTAL=$((TOTAL + 1))
if [[ ! -e "$STATE_FILE" && ! -e "$AGE_FILE" ]]; then
  record_pass "Clean completion removes stale sidecars"
else
  record_fail "Clean completion removes stale sidecars" "state=$([[ -e "$STATE_FILE" ]] && printf present || printf missing) age=$([[ -e "$AGE_FILE" ]] && printf present || printf missing)"
fi

status_finish
