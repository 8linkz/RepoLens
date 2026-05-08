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

# Regression test for issue #123: toolgate DAST/session lenses must make
# the happy-path DONE signal explicit at the end of each lens body.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

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
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "$needle" "$file"; then
    fail_with "$desc" "Unexpected: $needle"
  else
    pass_with "$desc"
  fi
}

echo "=== Test Suite: toolgate DONE termination (issue #123) ==="

EXPECTED_SENTENCE="After you have created all real GitHub issues for your confirmed findings (or if there are no findings to report), output **DONE** as the very first word of your response AND **DONE** as the very last word."

TARGET_FILES=(
  "prompts/lenses/toolgate/session-zap-api.md"
  "prompts/lenses/toolgate/session-k6.md"
  "prompts/lenses/toolgate/session-sqlmap.md"
  "prompts/lenses/toolgate/session-nuclei.md"
  "prompts/lenses/toolgate/session-schemathesis.md"
  "prompts/lenses/toolgate/session-lighthouse.md"
  "prompts/lenses/toolgate/session-zap.md"
  "prompts/lenses/toolgate/dast-api.md"
  "prompts/lenses/toolgate/dast-web.md"
  "prompts/lenses/toolgate/dast-injection.md"
  "prompts/lenses/toolgate/dast-scanner.md"
  "prompts/lenses/toolgate/dast-headers.md"
)

echo ""
echo "Test 1: all affected lens files exist"
for rel_path in "${TARGET_FILES[@]}"; do
  TOTAL=$((TOTAL + 1))
  if [[ -f "$SCRIPT_DIR/$rel_path" ]]; then
    pass_with "$rel_path exists"
  else
    fail_with "$rel_path exists" "Missing target file"
  fi
done

echo ""
echo "Test 2: the final non-empty paragraph is the standardized Termination block"
for rel_path in "${TARGET_FILES[@]}"; do
  file="$SCRIPT_DIR/$rel_path"
  heading="$(awk 'NF { prev=last; last=$0 } END { print prev }' "$file")"
  sentence="$(awk 'NF { last=$0 } END { print last }' "$file")"
  assert_eq "$rel_path final heading" "### Termination" "$heading"
  assert_eq "$rel_path final sentence" "$EXPECTED_SENTENCE" "$sentence"
done

echo ""
echo "Test 3: each affected lens has exactly one standardized happy-path instruction"
for rel_path in "${TARGET_FILES[@]}"; do
  file="$SCRIPT_DIR/$rel_path"
  count="$(grep -cF "$EXPECTED_SENTENCE" "$file")"
  assert_eq "$rel_path standardized instruction count" "1" "$count"
done

echo ""
echo "Test 4: session-zap keeps Safety Rules before the final Termination block"
ZAP_FILE="$SCRIPT_DIR/prompts/lenses/toolgate/session-zap.md"
assert_not_contains "old misplaced session-zap instruction removed" "After all issues are created, output **DONE**." "$ZAP_FILE"
assert_contains "session-zap still has Safety Rules" "### Safety Rules" "$ZAP_FILE"
TOTAL=$((TOTAL + 1))
zap_safety_line="$(grep -nF "### Safety Rules" "$ZAP_FILE" | tail -1 | cut -d: -f1)"
zap_term_line="$(grep -nF "### Termination" "$ZAP_FILE" | tail -1 | cut -d: -f1)"
if [[ "$zap_safety_line" =~ ^[0-9]+$ && "$zap_term_line" =~ ^[0-9]+$ && "$zap_safety_line" -lt "$zap_term_line" ]]; then
  pass_with "session-zap Safety Rules appear before Termination"
else
  fail_with "session-zap Safety Rules must appear before Termination" "Safety line: $zap_safety_line | Termination line: $zap_term_line"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
