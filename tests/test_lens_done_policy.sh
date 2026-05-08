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

# Generic lens DONE policy for issue #126.
#
# Lens bodies may mention DONE for setup-error or not-applicable branches, but
# those local mentions must not be the only nearby completion instruction. Any
# lens body that mentions DONE must end with the standardized happy-path
# Termination block. Lenses with no body-local DONE mention are not required to
# duplicate the base template's global Termination section.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

EXPECTED_SENTENCE="After you have created all real GitHub issues for your confirmed findings (or if there are no findings to report), output **DONE** as the very first word of your response AND **DONE** as the very last word."

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

assert_policy_result() {
  local desc="$1" file="$2" expected="$3"
  local rc=0

  TOTAL=$((TOTAL + 1))
  lens_done_policy_error "$file" >/dev/null || rc=$?

  if [[ "$expected" == "pass" && "$rc" -eq 0 ]]; then
    pass_with "$desc"
  elif [[ "$expected" == "fail" && "$rc" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected: $expected | Actual rc: $rc"
  fi
}

final_non_empty_heading() {
  awk 'NF { prev=last; last=$0 } END { print prev }' "$1"
}

final_non_empty_sentence() {
  awk 'NF { last=$0 } END { print last }' "$1"
}

lens_done_policy_error() {
  local file="$1"
  local heading sentence

  if ! grep -qF 'DONE' "$file"; then
    return 0
  fi

  heading="$(final_non_empty_heading "$file")"
  sentence="$(final_non_empty_sentence "$file")"

  if [[ "$heading" != "### Termination" ]]; then
    printf '%s: DONE-bearing lens must end with ### Termination\n' "$file"
    return 1
  fi

  if [[ "$sentence" != "$EXPECTED_SENTENCE" ]]; then
    printf '%s: DONE-bearing lens must end with the standardized happy-path DONE instruction\n' "$file"
    return 1
  fi

  return 0
}

echo "=== Test Suite: lens DONE policy (issue #126) ==="

TMP_DIR="$SCRIPT_DIR/logs/test-lens-done-policy.$$"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/conditional-only.md" <<'FIXTURE'
---
id: conditional-only
domain: test
name: Conditional Only
role: Test fixture
---

## Your Expert Focus

If the required tool is unavailable, explain that limitation and output DONE.

### Safety Rules

Do not change the target application.
FIXTURE

cat > "$TMP_DIR/with-termination.md" <<FIXTURE
---
id: with-termination
domain: test
name: With Termination
role: Test fixture
---

## Your Expert Focus

If the required tool is unavailable, explain that limitation and output DONE.

### Termination

$EXPECTED_SENTENCE
FIXTURE

cat > "$TMP_DIR/no-done.md" <<'FIXTURE'
---
id: no-done
domain: test
name: No Done
role: Test fixture
---

## Your Expert Focus

Audit the code path and report confirmed findings.
FIXTURE

echo ""
echo "Test 1: policy rejects conditional-only DONE mentions"
assert_policy_result "conditional-only DONE fixture fails" "$TMP_DIR/conditional-only.md" "fail"

echo ""
echo "Test 2: policy accepts DONE with final standardized Termination block"
assert_policy_result "standardized termination fixture passes" "$TMP_DIR/with-termination.md" "pass"

echo ""
echo "Test 3: policy does not force clean lenses to duplicate DONE"
assert_policy_result "no-DONE fixture passes" "$TMP_DIR/no-done.md" "pass"

echo ""
echo "Test 4: every repository lens with body-local DONE follows the policy"
done_count=0
while IFS= read -r rel_path; do
  file="$SCRIPT_DIR/$rel_path"
  done_count=$((done_count + 1))
  lens_done_policy_error "$file" >/dev/null
  assert_eq "$rel_path policy" "0" "$?"
done < <(cd "$SCRIPT_DIR" && grep -R -l 'DONE' prompts/lenses --include='*.md' | sort)

echo ""
echo "Test 5: repository has DONE-bearing lenses covered by this policy"
assert_eq "DONE-bearing lens count is nonzero" "yes" "$([[ "$done_count" -gt 0 ]] && echo yes || echo no)"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
