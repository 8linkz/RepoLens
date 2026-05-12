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

# Contract for issue #178: per-mode default --depth values preserve the
# D2 mapping and are resolved through the public core helper.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$SCRIPT_DIR/lib/core.sh"

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

assert_function_exists() {
  local desc="$1" fn="$2"
  TOTAL=$((TOTAL + 1))
  if declare -F "$fn" >/dev/null 2>&1; then
    pass_with "$desc"
    return 0
  fi

  fail_with "$desc" "Missing function: $fn"
  return 1
}

assert_table_entry() {
  local mode="$1" expected="$2" actual
  actual="${MODE_DEFAULT_DEPTH[$mode]:-__missing__}"
  assert_eq "MODE_DEFAULT_DEPTH[$mode] is $expected" "$expected" "$actual"
}

assert_resolved_depth() {
  local mode="$1" expected="$2" actual
  actual="$(mode_default_depth "$mode" 2>/dev/null || true)"
  assert_eq "mode_default_depth $mode returns $expected" "$expected" "$actual"
}

echo "=== Test Suite: issue #178 per-mode default depth ==="

if [[ -f "$CORE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$CORE"
else
  TOTAL=$((TOTAL + 1))
  fail_with "lib/core.sh exists" "Missing $CORE"
fi

echo ""
echo "=== Declarative default table ==="

TOTAL=$((TOTAL + 1))
if declare -p MODE_DEFAULT_DEPTH >/dev/null 2>&1; then
  pass_with "lib/core.sh exposes MODE_DEFAULT_DEPTH"

  for case in \
    "audit:3" \
    "feature:3" \
    "bugfix:3" \
    "custom:1" \
    "discover:1" \
    "deploy:1" \
    "opensource:1" \
    "content:1"; do
    IFS=: read -r mode expected <<<"$case"
    assert_table_entry "$mode" "$expected"
  done

  assert_table_entry "bugreport" "1"
else
  fail_with "lib/core.sh exposes MODE_DEFAULT_DEPTH" "Missing associative default table"
fi

echo ""
echo "=== Resolved defaults ==="

if assert_function_exists "lib/core.sh exposes mode_default_depth" "mode_default_depth"; then
  for case in \
    "audit:3" \
    "feature:3" \
    "bugfix:3" \
    "custom:1" \
    "discover:1" \
    "deploy:1" \
    "opensource:1" \
    "content:1"; do
    IFS=: read -r mode expected <<<"$case"
    assert_resolved_depth "$mode" "$expected"
  done

  assert_resolved_depth "bugreport" "1"
else
  echo "  SKIP: mode_default_depth entry checks wait for the resolver"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
