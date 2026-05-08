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

# Integration test for issue #121: status.json exposes the whole-run snapshot
# while a parallel run has an active lens and a queued lens.
#
# No real AI model is invoked. The test runs repolens.sh through its public
# CLI with a fake `codex` binary on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/tests/status_test_lib.sh"
trap status_cleanup EXIT

echo "=== aggregated status.json shape while run is active ==="
status_require_jq

PROJECT="$STATUS_TEST_TMPDIR/project"
FAKE_BIN="$STATUS_TEST_TMPDIR/bin"
OUT_FILE="$STATUS_TEST_TMPDIR/run.log"
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

if (( count == 1 )); then
  sleep 6
fi

echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

setsid env \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_TEST_STATE="$STATE_FILE" \
  REPOLENS_STATUS_INTERVAL=1 \
  REPOLENS_LENS_HEARTBEAT_INTERVAL=1 \
  REPOLENS_AGENT_TIMEOUT=15 \
  bash "$STATUS_TEST_ROOT/repolens.sh" \
    --project "$PROJECT" \
    --agent codex \
    --domain i18n \
    --change "status snapshot test" \
    --local \
    --yes \
    --parallel \
    --max-parallel 1 \
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
if [[ -n "$RUN_ID" ]] && wait_for_jq "$STATUS_FILE" \
  '.state == "running"
   and .total_lenses == 2
   and .counts.active == 1
   and .counts.queued == 1
   and .counts.completed == 0
   and (.active | any(.domain == "i18n" and .lens_id == "i18n-strings"))
   and (.queued | index("i18n/i18n-formatting"))' 80; then
  record_pass "Status snapshot appears with one active and one queued lens"
else
  record_fail "Status snapshot appears with one active and one queued lens" "missing or incomplete $STATUS_FILE"
fi

assert_jq_arg "Status run_id matches the active run" "$STATUS_FILE" run "$RUN_ID" '.run_id == $run'
assert_jq_arg "Status project is the audited project path" "$STATUS_FILE" project "$PROJECT" '.project == $project'
assert_jq "Status repo slug falls back to local/project" "$STATUS_FILE" '.repo == "local/project"'
assert_jq "Status metadata fields use documented types" "$STATUS_FILE" \
  '(.mode == "custom")
   and (.agent == "codex")
   and (.parallel == true)
   and (.max_parallel == 1)
   and (.started_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
   and (.updated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))'
assert_jq "Status counts partition the resolved lens list" "$STATUS_FILE" \
  '(.counts.queued + .counts.active + .counts.completed) == .total_lenses'
assert_jq "Status exposes numeric issue and completion counters" "$STATUS_FILE" \
  '(.counts.issues_created | type == "number")
   and (.completion_percentage | type == "number")
   and .completion_percentage >= 0
   and .completion_percentage <= 100'
assert_jq "Active entry includes heartbeat-derived timing fields" "$STATUS_FILE" \
  '.active
   | any(.domain == "i18n"
         and .lens_id == "i18n-strings"
         and (.pid | type == "number")
         and (.iteration | type == "number")
         and (.started_at | type == "string")
         and (.last_heartbeat_at | type == "string")
         and (.age_seconds | type == "number")
         and (.heartbeat_age_seconds | type == "number"))'
assert_jq "Queued excludes the active and completed lenses" "$STATUS_FILE" \
  '(.queued | index("i18n/i18n-formatting"))
   and (.queued | index("i18n/i18n-strings") | not)
   and (.completed | length == 0)'

terminate_run_group "$RUN_PID"
RUN_PID=""

status_finish
