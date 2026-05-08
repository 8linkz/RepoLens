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

# Integration test for issue #121: --resume status snapshots pick up existing
# .completed state and do not put completed lenses back in queued.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

echo "=== status.json resume completed and queued state ==="
status_require_jq

PROJECT="$STATUS_TEST_TMPDIR/project"
FAKE_BIN="$STATUS_TEST_TMPDIR/bin"
FIRST_OUT="$STATUS_TEST_TMPDIR/first-run.log"
SECOND_OUT="$STATUS_TEST_TMPDIR/resume-run.log"
STATE_FILE="$STATUS_TEST_TMPDIR/fake-codex-count"
mkdir -p "$FAKE_BIN"
status_setup_project "$PROJECT"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
state="${REPOLENS_TEST_STATE:?state path required}"
count=0
[[ -f "$state" ]] && count="$(cat "$state")"
count=$((count + 1))
printf '%s\n' "$count" > "$state"

if (( count >= 2 )); then
  sleep 6
fi

echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

set +e
env \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_TEST_STATE="$STATE_FILE" \
  REPOLENS_STATUS_INTERVAL=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=1 \
  REPOLENS_AGENT_TIMEOUT=15 \
  bash "$STATUS_TEST_ROOT/repolens.sh" \
    --project "$PROJECT" \
    --agent codex \
    --focus i18n-strings \
    --change "status resume seed" \
    --local \
    --yes \
    >"$FIRST_OUT" 2>&1
first_rc=$?
set -e

RUN_ID="$(parse_run_id "$FIRST_OUT")"
status_register_run_id "$RUN_ID"
SUMMARY_FILE="$STATUS_TEST_ROOT/logs/$RUN_ID/summary.json"
first_started_at="$(jq -r '.started_at // empty' "$SUMMARY_FILE" 2>/dev/null || true)"

assert_eq "Initial seed run exits cleanly" "0" "$first_rc"
assert_contains "Seed run completed i18n-strings" \
  "i18n/i18n-strings" "$(cat "$STATUS_TEST_ROOT/logs/$RUN_ID/.completed" 2>/dev/null || true)"

setsid env \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_TEST_STATE="$STATE_FILE" \
  REPOLENS_STATUS_INTERVAL=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=1 \
  REPOLENS_AGENT_TIMEOUT=15 \
  bash "$STATUS_TEST_ROOT/repolens.sh" \
    --project "$PROJECT" \
    --agent codex \
    --resume "$RUN_ID" \
    --domain i18n \
    --change "status resume test" \
    --local \
    --yes \
    --parallel \
    --max-parallel 1 \
    >"$SECOND_OUT" 2>&1 &
RUN_PID=$!

STATUS_FILE="$STATUS_TEST_ROOT/logs/$RUN_ID/status.json"
TOTAL=$((TOTAL + 1))
if wait_for_jq "$STATUS_FILE" \
  '.state == "running"
   and .total_lenses == 2
   and .counts.completed == 1
   and .counts.active == 1
   and .counts.queued == 0
   and (.completed | index("i18n/i18n-strings"))
   and (.active | any(.domain == "i18n" and .lens_id == "i18n-formatting"))
   and (.queued | index("i18n/i18n-strings") | not)
   and (.queued | index("i18n/i18n-formatting") | not)' 80; then
  record_pass "Resume status preserves completed lens and runs remaining lens"
else
  record_fail "Resume status preserves completed lens and runs remaining lens" "missing or incomplete $STATUS_FILE"
fi

assert_jq_arg "Resume status keeps original run started_at" "$STATUS_FILE" started "$first_started_at" '.started_at == $started'
assert_jq "Resume status count partition remains consistent" "$STATUS_FILE" \
  '(.counts.queued + .counts.active + .counts.completed) == .total_lenses'

terminate_run_group "$RUN_PID"
RUN_PID=""

status_finish
