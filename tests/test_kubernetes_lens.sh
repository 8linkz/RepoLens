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

# Tests for issue #66: kubernetes/security-context lens integration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/kubernetes/security-context.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"
COLORS_FILE="$SCRIPT_DIR/config/label-colors.json"

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    Missing: $needle"
  fi
}

assert_file_exists() {
  local desc="$1" filepath="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$filepath" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
    echo "    File not found: $filepath"
  fi
}

echo ""
echo "=== Test Suite: kubernetes/security-context lens (issue #66) ==="
echo ""

assert_file_exists "lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: Lens frontmatter is complete"
assert_contains "id frontmatter" "id: security-context" "$lens_content"
assert_contains "domain frontmatter" "domain: kubernetes" "$lens_content"
assert_contains "name frontmatter" "name: Pod Security Context" "$lens_content"
assert_contains "role frontmatter" "role: Kubernetes Security Specialist" "$lens_content"

echo ""
echo "Test 2: Lens body has required sections"
assert_contains "expert focus section" "## Your Expert Focus" "$lens_content"
assert_contains "hunt section" "### What You Hunt For" "$lens_content"
assert_contains "investigate section" "### How You Investigate" "$lens_content"

echo ""
echo "Test 3: Lens covers high-impact Kubernetes security controls"
for term in \
  "runAsNonRoot" \
  "allowPrivilegeEscalation" \
  "readOnlyRootFilesystem" \
  "capabilities" \
  "seccompProfile" \
  "hostPath" \
  "hostPID" \
  "hostNetwork" \
  "automountServiceAccountToken"; do
  assert_contains "mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 4: Kubernetes domain is registered once"
kubernetes_domain_count="$(jq '[.domains[] | select(.id == "kubernetes")] | length' "$DOMAINS_FILE")"
assert_eq "one kubernetes domain" "1" "$kubernetes_domain_count"

echo ""
echo "Test 5: Kubernetes domain is mode-less default audit coverage"
kubernetes_mode="$(jq -r '.domains[] | select(.id == "kubernetes") | .mode // "null"' "$DOMAINS_FILE")"
assert_eq "no mode field" "null" "$kubernetes_mode"

echo ""
echo "Test 6: Kubernetes domain contains security-context only"
kubernetes_lenses="$(jq -r '.domains[] | select(.id == "kubernetes") | .lenses | join(",")' "$DOMAINS_FILE")"
assert_eq "registered lens list" "security-context" "$kubernetes_lenses"

echo ""
echo "Test 7: Kubernetes label color is configured"
kubernetes_color="$(jq -r '.kubernetes // empty' "$COLORS_FILE")"
assert_eq "kubernetes label color" "326ce5" "$kubernetes_color"

echo ""
echo "Test 8: Audit-like mode resolution includes kubernetes/security-context"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
if grep -qxF "kubernetes/security-context" <<< "$audit_lenses"; then
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo "  PASS: audit mode includes kubernetes/security-context"
else
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo "  FAIL: audit mode should include kubernetes/security-context"
fi

echo ""
echo "Test 9: Exclusive modes do not include kubernetes/security-context"
for mode in discover deploy opensource content; do
  mode_lenses="$(jq -r --arg mode "$mode" \
    '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
  if grep -qxF "kubernetes/security-context" <<< "$mode_lenses"; then
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: $mode mode should not include kubernetes/security-context"
  else
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  PASS: $mode mode excludes kubernetes/security-context"
  fi
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi

exit 0
