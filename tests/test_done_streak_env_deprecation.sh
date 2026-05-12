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

# Contract for issue #178: the deprecated DONE_STREAK_REQUIRED alias remains
# observable, warns exactly once when present, and loses to --depth on conflict.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_PARENT="$SCRIPT_DIR/logs/test-done-streak-env-deprecation"
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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected output not to contain: $needle"
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
  printf '# env deprecation test\n' > "$project/README.md"
}

run_repolens_case() {
  local name="$1" env_depth="$2"
  shift 2

  local project="$TMPDIR/project-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/output-$name.txt"
  LAST_COUNT_FILE="$TMPDIR/count-$name.txt"
  : > "$LAST_COUNT_FILE"

  local env_args=(env -u DONE_STREAK_REQUIRED PATH="$FAKE_BIN:$PATH" REPOLENS_DEPTH_COUNT="$LAST_COUNT_FILE")
  if [[ -n "$env_depth" ]]; then
    env_args=(env PATH="$FAKE_BIN:$PATH" REPOLENS_DEPTH_COUNT="$LAST_COUNT_FILE" DONE_STREAK_REQUIRED="$env_depth")
  fi

  "${env_args[@]}" bash "$SCRIPT_DIR/repolens.sh" \
    --project "$project" \
    --agent codex \
    --focus naming \
    --local \
    --output "$TMPDIR/issues-$name" \
    --yes \
    "$@" >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
}

agent_call_count() {
  wc -l < "$LAST_COUNT_FILE" | tr -d ' '
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

warning_count() {
  grep -cF 'DONE_STREAK_REQUIRED is deprecated; use --depth N instead' "$LAST_OUTPUT_FILE" 2>/dev/null || true
}

echo "=== Test Suite: issue #178 DONE_STREAK_REQUIRED deprecation ==="

make_fake_codex

echo ""
echo "Test 1: DONE_STREAK_REQUIRED controls depth when --depth is unset"
run_repolens_case "env-only" "4"
register_created_run_id
assert_eq "env-only run exits successfully" "0" "$LAST_RC"
assert_eq "env-only run invokes fake agent four times" "4" "$(agent_call_count)"
assert_contains "env-only run logs DONE x4" "DONE x4" "$(last_output)"
assert_eq "env-only run emits exactly one deprecation warning" "1" "$(warning_count)"

echo ""
echo "Test 2: --depth wins over DONE_STREAK_REQUIRED but still warns"
run_repolens_case "flag-wins" "4" --depth 2
register_created_run_id
assert_eq "flag plus env exits successfully" "0" "$LAST_RC"
assert_eq "flag wins and invokes fake agent twice" "2" "$(agent_call_count)"
assert_contains "flag plus env logs DONE x2" "DONE x2" "$(last_output)"
assert_eq "flag plus env emits exactly one deprecation warning" "1" "$(warning_count)"

echo ""
echo "Test 3: --depth ignores invalid DONE_STREAK_REQUIRED but still warns"
run_repolens_case "flag-wins-invalid-env" "not-a-depth" --depth 2
register_created_run_id
assert_eq "flag plus invalid env exits successfully" "0" "$LAST_RC"
assert_eq "flag ignores invalid env and invokes fake agent twice" "2" "$(agent_call_count)"
assert_contains "flag plus invalid env logs DONE x2" "DONE x2" "$(last_output)"
assert_eq "flag plus invalid env emits exactly one deprecation warning" "1" "$(warning_count)"
assert_not_contains "flag plus invalid env does not validate ignored alias" "DONE_STREAK_REQUIRED must be between" "$(last_output)"

echo ""
echo "Test 4: invalid DONE_STREAK_REQUIRED still warns before validation failure"
run_repolens_case "env-invalid" "not-a-depth"
assert_eq "invalid env run exits non-zero" "1" "$LAST_RC"
assert_eq "invalid env does not invoke fake agent" "0" "$(agent_call_count)"
assert_contains "invalid env names bound" "DONE_STREAK_REQUIRED must be between 1 and 19" "$(last_output)"
assert_eq "invalid env emits exactly one deprecation warning" "1" "$(warning_count)"

echo ""
echo "Test 5: unset env uses per-mode default without warning"
run_repolens_case "env-unset-default" ""
register_created_run_id
assert_eq "env-unset default run exits successfully" "0" "$LAST_RC"
assert_eq "audit default invokes fake agent three times" "3" "$(agent_call_count)"
assert_contains "audit default logs DONE x3" "DONE x3" "$(last_output)"
assert_eq "env-unset default emits no deprecation warning" "0" "$(warning_count)"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
