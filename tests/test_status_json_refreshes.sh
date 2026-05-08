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

# Integration test for issue #121: the live status.json updater respects
# REPOLENS_STATUS_INTERVAL and keeps writing valid JSON while a lens is active.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

echo "=== status.json updated_at advances on the configured interval ==="
status_require_jq

PROJECT="$STATUS_TEST_TMPDIR/project"
FAKE_BIN="$STATUS_TEST_TMPDIR/bin"
OUT_FILE="$STATUS_TEST_TMPDIR/run.log"
mkdir -p "$FAKE_BIN"
status_setup_project "$PROJECT"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
sleep 5
echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

setsid env \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_STATUS_INTERVAL=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=1 \
  REPOLENS_AGENT_TIMEOUT=15 \
  bash "$STATUS_TEST_ROOT/repolens.sh" \
    --project "$PROJECT" \
    --agent codex \
    --focus i18n-strings \
    --change "status refresh test" \
    --local \
    --yes \
    >"$OUT_FILE" 2>&1 &
RUN_PID=$!

if RUN_ID="$(wait_for_run_id "$OUT_FILE")"; then
  status_register_run_id "$RUN_ID"
  TOTAL=$((TOTAL + 1))
  record_pass "Run id is logged"
else
  TOTAL=$((TOTAL + 1))
  record_fail "Run id is logged" "startup log did not contain run id"
fi

STATUS_FILE="$STATUS_TEST_ROOT/logs/$RUN_ID/status.json"

TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" ]] && wait_for_jq "$STATUS_FILE" '.state == "running" and .counts.active == 1' 60; then
  record_pass "Initial running status snapshot is valid JSON"
else
  record_fail "Initial running status snapshot is valid JSON" "missing $STATUS_FILE"
fi

first_updated_at="$(jq -r '.updated_at // empty' "$STATUS_FILE" 2>/dev/null || true)"
second_updated_at=""
for _ in {1..40}; do
  if jq -e . "$STATUS_FILE" >/dev/null 2>&1; then
    candidate="$(jq -r '.updated_at // empty' "$STATUS_FILE" 2>/dev/null || true)"
    if [[ -n "$first_updated_at" && -n "$candidate" && "$candidate" > "$first_updated_at" ]]; then
      second_updated_at="$candidate"
      break
    fi
  else
    break
  fi
  sleep 0.1
done

TOTAL=$((TOTAL + 1))
if [[ -n "$second_updated_at" ]]; then
  record_pass "updated_at advances after REPOLENS_STATUS_INTERVAL"
else
  record_fail "updated_at advances after REPOLENS_STATUS_INTERVAL" "first='${first_updated_at:-<empty>}' second='${second_updated_at:-<empty>}'"
fi

TOTAL=$((TOTAL + 1))
json_stayed_valid=true
for _ in {1..15}; do
  if ! jq -e . "$STATUS_FILE" >/dev/null 2>&1; then
    json_stayed_valid=false
    break
  fi
  sleep 0.1
done
if $json_stayed_valid; then
  record_pass "Status file stays valid JSON across refreshes"
else
  record_fail "Status file stays valid JSON across refreshes"
fi

terminate_run_group "$RUN_PID"
RUN_PID=""

status_finish
