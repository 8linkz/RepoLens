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

echo "=== stale heartbeat thresholds honor environment ==="
status_require_jq

RUN_ID="stale-thresholds"
LOG_BASE="$STATUS_TEST_TMPDIR/$RUN_ID"
HEARTBEAT_DIR="$LOG_BASE/.heartbeat"
HEARTBEAT_FILE="$HEARTBEAT_DIR/security__xss.json"
STATE_FILE="$HEARTBEAT_DIR/security__xss.state"
LOG_FILE="$LOG_BASE/$RUN_ID.log"
mkdir -p "$HEARTBEAT_DIR"
init_logging "$RUN_ID" "$LOG_BASE"

write_heartbeat() {
  local age_seconds="$1"
  local now_epoch last_heartbeat_at
  now_epoch="$(date -u +%s)"
  last_heartbeat_at="$(date -u -d "@$((now_epoch - age_seconds))" +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn \
    --arg run_id "$RUN_ID" \
    --arg domain "security" \
    --arg lens_id "xss" \
    --arg last_heartbeat_at "$last_heartbeat_at" \
    '{
      run_id: $run_id,
      domain: $domain,
      lens_id: $lens_id,
      pid: 4242,
      iteration: 1,
      started_at: $last_heartbeat_at,
      last_heartbeat_at: $last_heartbeat_at,
      state: "running"
    }' > "$HEARTBEAT_FILE"
}

log_count() {
  local pattern="$1"
  grep -Ec "$pattern" "$LOG_FILE" 2>/dev/null || true
}

export REPOLENS_STALE_WARN_SECONDS=10
export REPOLENS_STALE_ERROR_SECONDS=20

read -r resolved_warn resolved_error < <(resolve_status_stale_thresholds)
assert_eq "Warn threshold reads environment override" "10" "$resolved_warn"
assert_eq "Error threshold reads environment override" "20" "$resolved_error"

write_heartbeat 10
check_stale_heartbeats "$RUN_ID" "$LOG_BASE" "$HEARTBEAT_DIR"
assert_eq "Environment warn threshold fires at boundary" "1" "$(log_count '\[WARN\].*\[security/xss\] heartbeat stale')"
assert_eq "Environment warn transition writes warn state" "warn" "$(cat "$STATE_FILE")"

write_heartbeat 20
check_stale_heartbeats "$RUN_ID" "$LOG_BASE" "$HEARTBEAT_DIR"
assert_eq "Environment error threshold fires at boundary" "1" "$(log_count '\[ERROR\].*\[security/xss\] heartbeat silent')"
assert_eq "Environment error transition writes error state" "error" "$(cat "$STATE_FILE")"

unset REPOLENS_STALE_WARN_SECONDS
unset REPOLENS_STALE_ERROR_SECONDS

status_finish
