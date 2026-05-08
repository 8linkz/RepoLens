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

# Integration test for issue #120: clean lens completion removes the
# per-lens heartbeat file while leaving the run-level .heartbeat directory
# available for downstream consumers.
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

# shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap.
cleanup() {
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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc" "needle='$needle' not found"
  fi
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

parse_run_id() {
  local output_file="$1"
  grep -oE 'RepoLens run [^ ]+ starting' "$output_file" | head -1 | awk '{print $3}'
}

echo "=== per-lens heartbeat is removed after clean completion ==="

PROJECT="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
OUT_FILE="$TMPDIR/run.log"
mkdir -p "$FAKE_BIN"
setup_project "$PROJECT"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

set +e
env \
  PATH="$FAKE_BIN:$PATH" \
  REPOLENS_HEARTBEAT_INTERVAL=1 \
  REPOLENS_AGENT_TIMEOUT=20 \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT" \
    --agent codex \
    --focus i18n-strings \
    --mode audit \
    --local \
    --yes \
    --max-issues 1 \
    >"$OUT_FILE" 2>&1
run_rc=$?
set -e

RUN_ID="$(parse_run_id "$OUT_FILE")"
log_contents="$(cat "$OUT_FILE")"

assert_eq "RepoLens run exits cleanly" "0" "$run_rc"
assert_contains "Run log records focused lens completion" "DONE x1" "$log_contents"

HEARTBEAT_DIR="$SCRIPT_DIR/logs/$RUN_ID/.heartbeat"
HEARTBEAT_FILE="$HEARTBEAT_DIR/i18n__i18n-strings.json"

TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" && -d "$HEARTBEAT_DIR" ]]; then
  record_pass "Run-level .heartbeat directory exists"
else
  record_fail "Run-level .heartbeat directory exists" "missing $HEARTBEAT_DIR"
fi

TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" && ! -e "$HEARTBEAT_FILE" ]]; then
  record_pass "Heartbeat file is removed on clean lens completion"
else
  record_fail "Heartbeat file is removed on clean lens completion" "still present at $HEARTBEAT_FILE"
fi

sleep 1.2
TOTAL=$((TOTAL + 1))
if [[ -n "$RUN_ID" && ! -e "$HEARTBEAT_FILE" ]]; then
  record_pass "Heartbeat file does not reappear after cleanup interval"
else
  record_fail "Heartbeat file does not reappear after cleanup interval" "writer may still be running"
fi

completed_file="$SCRIPT_DIR/logs/$RUN_ID/.completed"
completed_contents=""
[[ -f "$completed_file" ]] && completed_contents="$(cat "$completed_file")"
assert_contains "Clean lens is marked completed for resume" "i18n/i18n-strings" "$completed_contents"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
