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

# Tests for the --rounds flag and REPOLENS_ROUNDS fallback.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=../lib/core.sh
source "$SCRIPT_DIR/lib/core.sh"

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-flag"
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
LAST_RC=0
LAST_RUN_ID=""
LAST_EXPLICIT_OUTPUT_DIR=""

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
    fail_with "$desc" "Did not expect output to contain: $needle"
  fi
}

assert_dir_exists() {
  local desc="$1" dir="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -d "$dir" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected directory at $dir"
  fi
}

assert_dir_missing() {
  local desc="$1" dir="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$dir" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect path at $dir"
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected file at $file"
  fi
}

assert_file_missing() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "$file" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect file at $file"
  fi
}

assert_json_query() {
  local desc="$1" file="$2" query="$3"
  TOTAL=$((TOTAL + 1))
  if jq -e "$query" "$file" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "jq query failed: $query"
  fi
}

make_fake_codex() {
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'DONE\n'
EOF
  chmod +x "$FAKE_BIN/codex"
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# rounds test\n' > "$project/README.md"
}

last_output() {
  cat "$LAST_OUTPUT_FILE"
}

register_created_run_id() {
  local run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$LAST_OUTPUT_FILE" 2>/dev/null | head -1 | awk '{print $3}')"
  LAST_RUN_ID="$run_id"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

run_repolens_case() {
  local name="$1"
  local env_rounds="$2"
  shift 2

  local project="$TMPDIR/project-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/output-$name.txt"

  # REPOLENS_MAX_ROUNDS=99 keeps the cross-mode safety ceiling (added in
  # issue #173) out of the way so per-mode rounds caps (up to 10) can still
  # be exercised without --i-know-this-is-expensive on the helper side.
  local env_args=(env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 PATH="$FAKE_BIN:$PATH")
  if [[ "$env_rounds" != "__unset__" ]]; then
    env_args=(env -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 PATH="$FAKE_BIN:$PATH" REPOLENS_ROUNDS="$env_rounds")
  fi

  # --i-know-this-is-expensive bypasses the rounds>=4 ack gate added in issue
   # #173 so the per-mode cap tests (--rounds 10) and the REPOLENS_ROUNDS=4
   # case continue to exercise the rounds flag itself, not the new ack gate.
  "${env_args[@]}" bash "$SCRIPT_DIR/repolens.sh" \
    --project "$project" \
    --agent codex \
    --local \
    --output "$TMPDIR/issues-$name" \
    --yes \
    --dry-run \
    --i-know-this-is-expensive \
    "$@" >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
  register_created_run_id
}

run_repolens_default_output_case() {
  local name="$1"
  shift

  local project="$TMPDIR/project-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/output-$name.txt"

  env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 PATH="$FAKE_BIN:$PATH" \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$project" \
      --agent codex \
      --local \
      --yes \
      --dry-run \
      "$@" >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
  register_created_run_id
}

run_repolens_explicit_output_case() {
  local name="$1"
  shift

  local project="$TMPDIR/project-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/output-$name.txt"
  LAST_EXPLICIT_OUTPUT_DIR="$TMPDIR/issues-$name"

  env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 PATH="$FAKE_BIN:$PATH" \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$project" \
      --agent codex \
      --focus naming \
      --local \
      --output "$LAST_EXPLICIT_OUTPUT_DIR" \
      --yes \
      --depth 1 \
      "$@" >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
  register_created_run_id
}

assert_rounds_table_entry() {
  local mode="$1"
  local expected="$2"
  local actual="${ROUNDS_CAP_BY_MODE[$mode]:-__missing__}"
  assert_eq "ROUNDS_CAP_BY_MODE[$mode] is $expected" "$expected" "$actual"
}

last_run_dir() {
  printf '%s/logs/%s\n' "$SCRIPT_DIR" "$LAST_RUN_ID"
}

echo ""
echo "=== Test Suite: --rounds flag ==="
echo ""

make_fake_codex

echo "Test 1: lib/core.sh exposes the per-mode rounds cap table"
if declare -p ROUNDS_CAP_BY_MODE >/dev/null 2>&1; then
  pass_with "lib/core.sh exposes ROUNDS_CAP_BY_MODE"
  for case in \
    "audit:1" \
    "feature:1" \
    "bugfix:1" \
    "custom:1" \
    "bugreport:10" \
    "deploy:1" \
    "opensource:1" \
    "content:1" \
    "discover:1"; do
    IFS=: read -r mode expected <<<"$case"
    assert_rounds_table_entry "$mode" "$expected"
  done
else
  TOTAL=$((TOTAL + 1))
  fail_with "lib/core.sh exposes ROUNDS_CAP_BY_MODE" "Missing associative cap table"
fi

echo ""
echo "Test 2: default audit dry-run surfaces one round"
run_repolens_case "default-audit" "__unset__"
assert_eq "default audit dry-run exits successfully" "0" "$LAST_RC"
assert_contains "default audit dry-run shows one round" "Rounds:      1" "$(last_output)"

echo ""
echo "Test 3: default dry-run surfaces one round for every other accepted mode"
for mode in feature bugfix discover deploy opensource content; do
  run_repolens_case "default-$mode" "__unset__" --mode "$mode"
  assert_eq "$mode default dry-run exits successfully" "0" "$LAST_RC"
  assert_contains "$mode default dry-run shows one round" "Rounds:      1" "$(last_output)"
done

run_repolens_case "default-custom" "__unset__" --mode custom --change "Test change"
assert_eq "custom default dry-run exits successfully" "0" "$LAST_RC"
assert_contains "custom default dry-run shows one round" "Rounds:      1" "$(last_output)"

echo ""
echo "Test 4: --rounds controls the dry-run round count"
run_repolens_case "flag-rounds" "__unset__" --mode bugreport --bug-report "Test bug report" --rounds 3
assert_eq "--rounds 3 dry-run exits successfully" "0" "$LAST_RC"
assert_contains "--rounds 3 is displayed" "Rounds:      3" "$(last_output)"
run_dir="$(last_run_dir)"
assert_dir_exists "dry-run creates run-level rounds directory" "$run_dir/rounds"
assert_dir_exists "dry-run creates final directory" "$run_dir/final"
assert_dir_exists "dry-run creates final/filed directory" "$run_dir/final/filed"
for round in 1 2 3; do
  assert_dir_exists "dry-run creates round-$round directory" "$run_dir/rounds/round-$round"
  assert_dir_exists "dry-run creates round-$round lens-outputs directory" "$run_dir/rounds/round-$round/lens-outputs"
  assert_file_exists "dry-run creates round-$round metadata" "$run_dir/rounds/round-$round/metadata.json"
  assert_file_missing "dry-run does not mark round-$round completed" "$run_dir/rounds/round-$round/.completed"
done
assert_dir_missing "dry-run does not create round-4 for --rounds 3" "$run_dir/rounds/round-4"
assert_json_query "round-2 metadata records total rounds and lens ids" \
                  "$run_dir/rounds/round-2/metadata.json" \
                  '.round_number == 2 and .rounds_total == 3 and (.lens_ids | length) == .lens_count'

echo ""
echo "Test 4b: local dry-run defaults markdown output to round-1 lens-outputs"
run_repolens_default_output_case "default-output-root" --domain i18n
assert_eq "default output dry-run exits successfully" "0" "$LAST_RC"
run_dir="$(last_run_dir)"
assert_contains "default output is the round lens output root" \
                "$run_dir/rounds/round-1/lens-outputs" \
                "$(last_output)"
assert_dir_exists "default output root exists under round-1" "$run_dir/rounds/round-1/lens-outputs"

echo ""
echo "Test 4c: local --output keeps lens output under caller-provided root"
run_repolens_explicit_output_case "explicit-output-root"
assert_eq "explicit output run exits successfully" "0" "$LAST_RC"
run_dir="$(last_run_dir)"
assert_dir_exists "explicit output lens directory is caller-rooted" \
                  "$LAST_EXPLICIT_OUTPUT_DIR/code-quality/naming"
assert_dir_missing "explicit output does not reroute lens directory to round logs" \
                   "$run_dir/rounds/round-1/lens-outputs/code-quality/naming"

echo ""
echo "Test 5: REPOLENS_ROUNDS is used when --rounds is absent"
run_repolens_case "env-rounds" "4" --mode bugreport --bug-report "Test bug report"
assert_eq "REPOLENS_ROUNDS dry-run exits successfully" "0" "$LAST_RC"
assert_contains "REPOLENS_ROUNDS is displayed" "Rounds:      4" "$(last_output)"

echo ""
echo "Test 6: --rounds wins over REPOLENS_ROUNDS"
run_repolens_case "flag-wins-env" "4" --mode bugreport --bug-report "Test bug report" --rounds 2
assert_eq "flag plus env dry-run exits successfully" "0" "$LAST_RC"
assert_contains "flag value is displayed" "Rounds:      2" "$(last_output)"
assert_not_contains "env value is not displayed as rounds" "Rounds:      4" "$(last_output)"

echo ""
echo "Test 7: invalid REPOLENS_ROUNDS is ignored when --rounds is provided"
run_repolens_case "flag-wins-invalid-env" "abc" --mode bugreport --bug-report "Test bug report" --rounds 2
assert_eq "valid flag with invalid env still exits successfully" "0" "$LAST_RC"
assert_contains "valid flag value is displayed despite invalid env" "Rounds:      2" "$(last_output)"

echo ""
echo "Test 8: bugreport accepts its multi-round cap"
run_repolens_case "cap-bugreport" "__unset__" --mode bugreport --bug-report "Test bug report" --rounds 10
assert_eq "bugreport accepts --rounds 10" "0" "$LAST_RC"
assert_contains "bugreport displays --rounds 10" "Rounds:      10" "$(last_output)"

echo ""
echo "Test 9: one-round modes reject values over their cap"
for mode in audit feature bugfix deploy discover opensource content; do
  run_repolens_case "cap-over-$mode" "__unset__" --mode "$mode" --rounds 2
  assert_eq "$mode rejects --rounds 2" "1" "$LAST_RC"
  assert_contains "$mode cap error names mode and cap" "--rounds 2 exceeds cap for mode '$mode' (max: 1)" "$(last_output)"
done

run_repolens_case "cap-over-custom" "__unset__" --mode custom --change "Test change" --rounds 2
assert_eq "custom rejects --rounds 2" "1" "$LAST_RC"
assert_contains "custom cap error names mode and cap" "--rounds 2 exceeds cap for mode 'custom' (max: 1)" "$(last_output)"

echo ""
echo "Test 10: bugreport rejects values over its cap"
run_repolens_case "cap-over-bugreport" "__unset__" --mode bugreport --bug-report "Test bug report" --rounds 11
assert_eq "bugreport rejects --rounds 11" "1" "$LAST_RC"
assert_contains "bugreport cap error names mode and cap" "--rounds 11 exceeds cap for mode 'bugreport' (max: 10)" "$(last_output)"

echo ""
echo "Test 11: --rounds rejects invalid values"
for value in 0 -1 abc ""; do
  safe_name="${value:-empty}"
  safe_name="${safe_name//[^A-Za-z0-9_-]/_}"
  run_repolens_case "invalid-flag-$safe_name" "__unset__" --rounds "$value"
  assert_eq "--rounds '$value' exits non-zero" "1" "$LAST_RC"
  assert_contains "--rounds '$value' names positive integer validation" "--rounds must be a positive integer" "$(last_output)"
done

echo ""
echo "Test 12: REPOLENS_ROUNDS rejects invalid values"
for value in 0 -1 abc ""; do
  safe_name="${value:-empty}"
  safe_name="${safe_name//[^A-Za-z0-9_-]/_}"
  run_repolens_case "invalid-env-$safe_name" "$value"
  assert_eq "REPOLENS_ROUNDS='$value' exits non-zero" "1" "$LAST_RC"
  assert_contains "REPOLENS_ROUNDS='$value' names positive integer validation" "REPOLENS_ROUNDS must be a positive integer" "$(last_output)"
done

echo ""
echo "Test 13: REPOLENS_ROUNDS is subject to per-mode caps"
run_repolens_case "env-cap-over-bugreport" "11" --mode bugreport --bug-report "Test bug report"
assert_eq "bugreport rejects REPOLENS_ROUNDS=11" "1" "$LAST_RC"
assert_contains "bugreport env cap error names mode and cap" "REPOLENS_ROUNDS 11 exceeds cap for mode 'bugreport' (max: 10)" "$(last_output)"

for mode in audit feature bugfix deploy discover opensource content; do
  run_repolens_case "env-cap-over-$mode" "2" --mode "$mode"
  assert_eq "$mode rejects REPOLENS_ROUNDS=2" "1" "$LAST_RC"
  assert_contains "$mode env cap error names mode and cap" "REPOLENS_ROUNDS 2 exceeds cap for mode '$mode' (max: 1)" "$(last_output)"
done

run_repolens_case "env-cap-over-custom" "2" --mode custom --change "Test change"
assert_eq "custom rejects REPOLENS_ROUNDS=2" "1" "$LAST_RC"
assert_contains "custom env cap error names mode and cap" "REPOLENS_ROUNDS 2 exceeds cap for mode 'custom' (max: 1)" "$(last_output)"

echo ""
echo "Test 14: --rounds requires an argument"
run_repolens_case "missing-flag-value" "__unset__" --rounds
assert_eq "bare --rounds exits non-zero" "1" "$LAST_RC"
assert_contains "bare --rounds names missing positive integer argument" "Option --rounds requires a positive integer argument." "$(last_output)"

echo ""
echo "Test 15: custom mode requires --change even in dry-run"
run_repolens_case "custom-dry-run-without-change" "__unset__" --mode custom --rounds 1
assert_eq "custom dry-run without --change exits non-zero" "1" "$LAST_RC"
assert_contains "custom dry-run without --change keeps the change guard" "Mode 'custom' requires --change \"your change statement\"" "$(last_output)"

custom_project="$TMPDIR/project-custom-without-change"
make_project "$custom_project"
LAST_OUTPUT_FILE="$TMPDIR/output-custom-without-change.txt"
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 PATH="$FAKE_BIN:$PATH" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$custom_project" \
    --agent codex \
    --local \
    --output "$TMPDIR/issues-custom-without-change" \
    --yes \
    --mode custom \
    --i-know-this-is-expensive \
    --rounds 1 >"$LAST_OUTPUT_FILE" 2>&1
LAST_RC=$?
register_created_run_id
assert_eq "custom non-dry-run without --change exits non-zero" "1" "$LAST_RC"
assert_contains "custom non-dry-run without --change keeps the change guard" "Mode 'custom' requires --change \"your change statement\"" "$(last_output)"

echo ""
echo "Test 16: usage documents --rounds and REPOLENS_ROUNDS"
usage_output="$(env -u REPOLENS_ROUNDS bash "$SCRIPT_DIR/repolens.sh" --help 2>&1)"
assert_contains "usage includes --rounds" "--rounds <n>" "$usage_output"
assert_contains "usage notes only bugreport supports multi-round" "only --mode bugreport" "$usage_output"
assert_contains "usage includes REPOLENS_ROUNDS" "REPOLENS_ROUNDS" "$usage_output"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
