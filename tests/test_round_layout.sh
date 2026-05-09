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

# Tests for issue #147: round state layout under logs/<run-id>/rounds/round-N.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUNDS_LIB="$SCRIPT_DIR/lib/rounds.sh"

PASS=0
FAIL=0
TOTAL=0

TMP_PARENT="$SCRIPT_DIR/logs/test-round-layout"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

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

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit status 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit status"
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

assert_function_exists() {
  local desc="$1" function_name="$2"
  TOTAL=$((TOTAL + 1))
  if declare -F "$function_name" >/dev/null 2>&1; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing function: $function_name"
  fi
}

call_helper() {
  local function_name="$1"
  shift
  if declare -F "$function_name" >/dev/null 2>&1; then
    "$function_name" "$@"
  else
    return 127
  fi
}

functions_available() {
  local function_name
  for function_name in "$@"; do
    declare -F "$function_name" >/dev/null 2>&1 || return 1
  done
  return 0
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

reset_case() {
  local name="$1"
  RUN_ID="layout-$name"
  LOG_BASE="$TMPDIR/$name/logs/$RUN_ID"
  mkdir -p "$LOG_BASE"
}

echo "=== round layout helpers (issue #147) ==="

TOTAL=$((TOTAL + 1))
if [[ -f "$ROUNDS_LIB" ]]; then
  pass_with "lib/rounds.sh exists"
else
  fail_with "lib/rounds.sh exists" "Expected module at $ROUNDS_LIB"
  finish
fi

# shellcheck disable=SC1090
source "$ROUNDS_LIB"

echo ""
echo "Test 1: public path helpers resolve the round artifact contract from LOG_BASE"
reset_case "paths"
for function_name in \
  round_dir \
  round_lens_outputs_dir \
  round_digest_path \
  round_metadata_path \
  round_completed_marker \
  final_dir; do
  assert_function_exists "$function_name is defined" "$function_name"
done

if functions_available \
  round_dir \
  round_lens_outputs_dir \
  round_digest_path \
  round_metadata_path \
  round_completed_marker \
  final_dir; then
  actual_round_dir="$(call_helper round_dir "$RUN_ID" 3)"
  actual_lens_outputs="$(call_helper round_lens_outputs_dir "$RUN_ID" 3)"
  actual_digest="$(call_helper round_digest_path "$RUN_ID" 3)"
  actual_metadata="$(call_helper round_metadata_path "$RUN_ID" 3)"
  actual_completed="$(call_helper round_completed_marker "$RUN_ID" 3)"
  actual_final="$(call_helper final_dir "$RUN_ID")"

  assert_eq "round_dir points at logs/run/rounds/round-N" "$LOG_BASE/rounds/round-3" "$actual_round_dir"
  assert_eq "round_lens_outputs_dir points under the round" "$LOG_BASE/rounds/round-3/lens-outputs" "$actual_lens_outputs"
  assert_eq "round_digest_path points under the round" "$LOG_BASE/rounds/round-3/digest.md" "$actual_digest"
  assert_eq "round_metadata_path points under the round" "$LOG_BASE/rounds/round-3/metadata.json" "$actual_metadata"
  assert_eq "round_completed_marker is the visible barrier file" "$LOG_BASE/rounds/round-3/.completed" "$actual_completed"
  assert_eq "final_dir points at the run-level final directory" "$LOG_BASE/final" "$actual_final"
fi

echo ""
echo "Test 2: init_run_layout creates the single-round skeleton without a completion barrier"
reset_case "single"
if functions_available init_run_layout; then
  call_helper init_run_layout "$RUN_ID" 1 2 "security/injection" "quality/dead-code"
  rc=$?
  assert_success "init_run_layout exits successfully for --rounds 1" "$rc"
  assert_dir_exists "round-1 directory exists" "$LOG_BASE/rounds/round-1"
  assert_dir_exists "round-1 lens-outputs directory exists" "$LOG_BASE/rounds/round-1/lens-outputs"
  assert_file_exists "round-1 metadata exists" "$LOG_BASE/rounds/round-1/metadata.json"
  assert_dir_exists "final directory exists" "$LOG_BASE/final"
  assert_dir_exists "final/filed directory exists" "$LOG_BASE/final/filed"
  assert_dir_missing "round-2 is not created for --rounds 1" "$LOG_BASE/rounds/round-2"
  assert_file_missing "partial round has no .completed barrier" "$LOG_BASE/rounds/round-1/.completed"
else
  assert_function_exists "init_run_layout is defined" "init_run_layout"
fi

echo ""
echo "Test 3: init_run_layout creates every requested round for --rounds 3"
reset_case "multi"
if functions_available init_run_layout; then
  call_helper init_run_layout "$RUN_ID" 3 2 "security/injection" "quality/dead-code"
  rc=$?
  assert_success "init_run_layout exits successfully for --rounds 3" "$rc"
  for round in 1 2 3; do
    assert_dir_exists "round-$round directory exists" "$LOG_BASE/rounds/round-$round"
    assert_dir_exists "round-$round lens-outputs directory exists" "$LOG_BASE/rounds/round-$round/lens-outputs"
    assert_file_exists "round-$round metadata exists" "$LOG_BASE/rounds/round-$round/metadata.json"
    assert_file_missing "round-$round is not marked completed by layout initialization" "$LOG_BASE/rounds/round-$round/.completed"
  done
  assert_dir_missing "round-4 is not created for --rounds 3" "$LOG_BASE/rounds/round-4"
else
  assert_function_exists "init_run_layout is defined for multi-round layout" "init_run_layout"
fi

echo ""
echo "Test 4: write_round_metadata emits the required JSON schema"
reset_case "metadata"
mkdir -p "$LOG_BASE/rounds/round-2"
metadata_path="$LOG_BASE/rounds/round-2/metadata.json"
if functions_available write_round_metadata; then
  call_helper write_round_metadata "$RUN_ID" 2 2 3 "security/injection" "quality/dead-code"
  rc=$?
  assert_success "write_round_metadata exits successfully" "$rc"
  assert_file_exists "metadata.json is written" "$metadata_path"
  assert_json_query "round_number is numeric and 1-based" "$metadata_path" '.round_number == 2'
  assert_json_query "breadth is numeric" "$metadata_path" '.breadth == 2'
  assert_json_query "rounds_total is numeric" "$metadata_path" '.rounds_total == 3'
  assert_json_query "lens_count matches selected lenses" "$metadata_path" '.lens_count == 2'
  assert_json_query "lens_ids preserves selected domain/lens ids" "$metadata_path" '.lens_ids == ["security/injection", "quality/dead-code"]'
  assert_json_query "start_ts is ISO-8601 UTC" "$metadata_path" '.start_ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'
  assert_json_query "end_ts is absent before finalization" "$metadata_path" 'has("end_ts") | not'
else
  assert_function_exists "write_round_metadata is defined" "write_round_metadata"
fi

echo ""
echo "Test 5: finalize_round writes end_ts and the round barrier last"
reset_case "finalize"
mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs"
if functions_available write_round_metadata finalize_round is_round_completed; then
  call_helper write_round_metadata "$RUN_ID" 1 1 1 "security/injection"
  if call_helper is_round_completed "$RUN_ID" 1; then
    before_completed=0
  else
    before_completed=$?
  fi
  assert_failure "is_round_completed is false before finalize_round" "$before_completed"
  call_helper finalize_round "$RUN_ID" 1
  rc=$?
  assert_success "finalize_round exits successfully" "$rc"
  assert_file_exists "round .completed barrier is written" "$LOG_BASE/rounds/round-1/.completed"
  if call_helper is_round_completed "$RUN_ID" 1; then
    after_completed=0
  else
    after_completed=$?
  fi
  assert_success "is_round_completed is true after finalize_round" "$after_completed"
  assert_json_query "end_ts is ISO-8601 UTC after finalization" "$LOG_BASE/rounds/round-1/metadata.json" '.end_ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'
else
  assert_function_exists "write_round_metadata is defined for finalize test" "write_round_metadata"
  assert_function_exists "finalize_round is defined" "finalize_round"
  assert_function_exists "is_round_completed is defined" "is_round_completed"
fi

echo ""
echo "Test 6: layout initialization is idempotent and preserves existing artifacts"
reset_case "idempotent"
mkdir -p "$LOG_BASE/rounds/round-1/lens-outputs" "$LOG_BASE/final"
printf '{"round_number":1,"start_ts":"2026-01-01T00:00:00Z","custom":"keep"}\n' > "$LOG_BASE/rounds/round-1/metadata.json"
printf 'existing digest\n' > "$LOG_BASE/rounds/round-1/digest.md"
printf 'existing finding\n' > "$LOG_BASE/rounds/round-1/lens-outputs/001-existing.md"
printf '{"clusters":[]}\n' > "$LOG_BASE/final/manifest.json"

if functions_available init_run_layout; then
  call_helper init_run_layout "$RUN_ID" 1 1 "security/injection"
  rc=$?
  assert_success "idempotent init_run_layout exits successfully" "$rc"
  assert_eq "metadata.json is not clobbered on resume" \
            '{"round_number":1,"start_ts":"2026-01-01T00:00:00Z","custom":"keep"}' \
            "$(tr -d '\n' < "$LOG_BASE/rounds/round-1/metadata.json")"
  assert_eq "digest.md is preserved" "existing digest" "$(tr -d '\n' < "$LOG_BASE/rounds/round-1/digest.md")"
  assert_eq "lens output markdown is preserved" "existing finding" "$(tr -d '\n' < "$LOG_BASE/rounds/round-1/lens-outputs/001-existing.md")"
  assert_eq "final manifest is preserved" '{"clusters":[]}' "$(tr -d '\n' < "$LOG_BASE/final/manifest.json")"
else
  assert_function_exists "init_run_layout is defined for idempotency" "init_run_layout"
fi

finish
