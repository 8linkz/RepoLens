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

# Contract for issue #178: --depth N produces exactly N within-lens DONE
# confirmations and exactly N agent invocations for a single focused lens.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_PARENT="$SCRIPT_DIR/logs/test-depth-overrides-streak"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}

trap cleanup EXIT

PASS=0
FAIL=0
TOTAL=0
FAKE_BIN="$TMPDIR/bin"
LAST_OUTPUT_FILE=""
LAST_COUNT_FILE=""
LAST_RC=0

pass_with() {
  local desc="$1"
  PASS=$((PASS + 1))
  echo "  PASS: $desc"
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
    fail_with "$desc" "Expected: $expected | Actual: $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected output to contain: $needle"
  fi
}

make_fake_codex() {
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'run\n' >> "$REPOLENS_DEPTH_COUNT"
printf 'DONE\n'
EOF
  chmod +x "$FAKE_BIN/codex"
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# depth override test\n' > "$project/README.md"
}

run_depth_case() {
  local name="$1" depth="$2"
  local project="$TMPDIR/project-$name"

  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/output-$name.txt"
  LAST_COUNT_FILE="$TMPDIR/count-$name.txt"
  : > "$LAST_COUNT_FILE"

  env -u DONE_STREAK_REQUIRED \
    PATH="$FAKE_BIN:$PATH" \
    REPOLENS_DEPTH_COUNT="$LAST_COUNT_FILE" \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$project" \
      --agent codex \
      --focus naming \
      --local \
      --output "$TMPDIR/issues-$name" \
      --yes \
      --depth "$depth" \
      >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
}

agent_call_count() {
  wc -l < "$LAST_COUNT_FILE" | tr -d ' '
}

done_detection_count() {
  grep -cF 'DONE detected' "$LAST_OUTPUT_FILE" 2>/dev/null || true
}

last_output() {
  cat "$LAST_OUTPUT_FILE"
}

register_created_run_id() {
  local run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$LAST_OUTPUT_FILE" 2>/dev/null | head -1 | awk '{print $3}')"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

assert_depth_run() {
  local depth="$1" name="depth-$1"

  echo ""
  echo "Test: --depth $depth produces $depth DONE-streak iterations"
  run_depth_case "$name" "$depth"
  register_created_run_id

  assert_eq "--depth $depth exits successfully" "0" "$LAST_RC"
  assert_eq "--depth $depth invokes fake agent $depth time(s)" "$depth" "$(agent_call_count)"
  assert_eq "--depth $depth logs $depth DONE confirmation(s)" "$depth" "$(done_detection_count)"
  assert_contains "--depth $depth logs lens completion threshold" "DONE x${depth}" "$(last_output)"
}

echo "=== Test Suite: issue #178 --depth iteration override ==="

make_fake_codex

assert_depth_run "1"
assert_depth_run "3"
assert_depth_run "5"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
