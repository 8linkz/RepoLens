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

# Integration tests for issue #214's Claude JSON envelope wrapper.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/core.sh"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail_with() {
  local desc="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  echo "  FAIL: $desc"
  if [[ -n "$detail" ]]; then
    printf '    %s\n' "$detail"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing file $path"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$path" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Unexpected file $path"
  fi
}

echo "=== Claude JSON envelope wrapper (issue #214) ==="

if ! command -v timeout >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: timeout(1) or jq not available"
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  exit 0
fi

PROJECT="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
mkdir -p "$PROJECT" "$FAKE_BIN"

cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

printf '%s\n' "$*" > "${FAKE_CLAUDE_ARGS_FILE:?}"

case "${FAKE_CLAUDE_MODE:-success}" in
  success)
    cat <<'JSON'
{"result":"DONE\nStructured result text\n","is_error":false,"stop_reason":"end_turn"}
JSON
    ;;
  refusal)
    cat <<'JSON'
{"result":"I cannot help with that.","is_error":false,"stop_reason":"refusal"}
JSON
    ;;
  malformed)
    printf 'legacy text output\nDONE\n'
    ;;
  *)
    printf 'unknown fake mode: %s\n' "${FAKE_CLAUDE_MODE:-}" >&2
    exit 2
    ;;
esac
SH
chmod +x "$FAKE_BIN/claude"

ARGS_FILE="$TMPDIR/claude-args.txt"
RESULT_FILE="$TMPDIR/result.txt"
ENVELOPE_FILE="$TMPDIR/nested/envelope.json"

PATH="$FAKE_BIN:$PATH" \
  FAKE_CLAUDE_ARGS_FILE="$ARGS_FILE" \
  FAKE_CLAUDE_MODE=success \
  run_agent claude "Prompt text" "$PROJECT" 5 1 "$ENVELOPE_FILE" > "$RESULT_FILE" 2>&1
rc=$?
assert_eq "Claude JSON wrapper returns agent status" "0" "$rc"
assert_eq "Claude invocation requests JSON output" "--dangerously-skip-permissions --output-format json -p Prompt text" "$(cat "$ARGS_FILE")"
assert_eq "Claude JSON wrapper emits result text only" $'DONE\nStructured result text' "$(cat "$RESULT_FILE")"
assert_file_exists "Claude JSON wrapper writes explicit envelope sidecar" "$ENVELOPE_FILE"
assert_eq "Envelope sidecar preserves stop_reason" "end_turn" "$(jq -r '.stop_reason' "$ENVELOPE_FILE")"

ENV_ENVELOPE_FILE="$TMPDIR/env/envelope.json"
rm -f "$RESULT_FILE"
PATH="$FAKE_BIN:$PATH" \
  FAKE_CLAUDE_ARGS_FILE="$ARGS_FILE" \
  FAKE_CLAUDE_MODE=refusal \
  REPOLENS_AGENT_ENVELOPE_FILE="$ENV_ENVELOPE_FILE" \
  run_agent claude "Refusal prompt" "$PROJECT" 5 1 > "$RESULT_FILE" 2>&1
rc=$?
assert_eq "Claude JSON wrapper honors env envelope path" "0" "$rc"
assert_eq "Claude JSON wrapper emits refusal result text" "I cannot help with that." "$(cat "$RESULT_FILE")"
assert_file_exists "Claude JSON wrapper writes env envelope sidecar" "$ENV_ENVELOPE_FILE"
assert_eq "Env envelope sidecar preserves refusal stop_reason" "refusal" "$(jq -r '.stop_reason' "$ENV_ENVELOPE_FILE")"

MALFORMED_ENVELOPE_FILE="$TMPDIR/malformed/envelope.json"
rm -f "$RESULT_FILE"
PATH="$FAKE_BIN:$PATH" \
  FAKE_CLAUDE_ARGS_FILE="$ARGS_FILE" \
  FAKE_CLAUDE_MODE=malformed \
  run_agent claude "Legacy prompt" "$PROJECT" 5 1 "$MALFORMED_ENVELOPE_FILE" > "$RESULT_FILE" 2>&1
rc=$?
assert_eq "Malformed Claude output returns agent status" "0" "$rc"
assert_eq "Malformed Claude output passes raw text through" $'legacy text output\nDONE' "$(cat "$RESULT_FILE")"
assert_file_missing "Malformed Claude output does not write envelope sidecar" "$MALFORMED_ENVELOPE_FILE"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
