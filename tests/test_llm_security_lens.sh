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

# Tests for issue #73: llm-security/output-sanitization lens integration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/llm-security/output-sanitization.md"
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
echo "=== Test Suite: llm-security lens (issue #73) ==="
echo ""

assert_file_exists "output-sanitization lens prompt exists" "$LENS_FILE"

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 1: output-sanitization frontmatter is complete"
assert_contains "id frontmatter" "id: output-sanitization" "$lens_content"
assert_contains "domain frontmatter" "domain: llm-security" "$lens_content"
assert_contains "name frontmatter" "name: LLM Output Sanitization & Rendering Safety" "$lens_content"
assert_contains "role frontmatter" "role: LLM Output Security Specialist" "$lens_content"

echo ""
echo "Test 2: output-sanitization body has required sections"
assert_contains "expert focus section" "## Your Expert Focus" "$lens_content"
assert_contains "hunt section" "### What You Hunt For" "$lens_content"
assert_contains "investigate section" "### How You Investigate" "$lens_content"

echo ""
echo "Test 3: output-sanitization covers LLM output rendering and injection risks"
for term in \
  "LLM output" \
  "Stored XSS" \
  "dangerouslySetInnerHTML" \
  "v-html" \
  "DOMPurify" \
  "bleach" \
  "sanitize-html" \
  "GitHub Issues" \
  "Jira" \
  "Slack" \
  "javascript:" \
  "data:" \
  "Pydantic" \
  "Zod" \
  "JSON Schema" \
  "Content-Security-Policy"; do
  assert_contains "prompt mentions $term" "$term" "$lens_content"
done

echo ""
echo "Test 4: llm-security domain is registered once"
domain_count="$(jq '[.domains[] | select(.id == "llm-security")] | length' "$DOMAINS_FILE")"
assert_eq "one llm-security domain" "1" "$domain_count"

echo ""
echo "Test 5: llm-security domain is mode-less default audit coverage"
domain_mode="$(jq -r '.domains[] | select(.id == "llm-security") | .mode // "null"' "$DOMAINS_FILE")"
assert_eq "no mode field" "null" "$domain_mode"

echo ""
echo "Test 6: llm-security domain contains output-sanitization"
domain_lenses="$(jq -r '.domains[] | select(.id == "llm-security") | .lenses | join(",")' "$DOMAINS_FILE")"
assert_eq "registered lens list" "output-sanitization" "$domain_lenses"

echo ""
echo "Test 7: llm-security label color is configured"
label_color="$(jq -r '."llm-security" // empty' "$COLORS_FILE")"
assert_eq "llm-security label color" "b91c1c" "$label_color"

echo ""
echo "Test 8: Audit-like mode resolution includes llm-security/output-sanitization"
audit_lenses="$(jq -r --arg mode "audit" \
  '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
if grep -qxF "llm-security/output-sanitization" <<< "$audit_lenses"; then
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo "  PASS: audit mode includes llm-security/output-sanitization"
else
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo "  FAIL: audit mode should include llm-security/output-sanitization"
fi

echo ""
echo "Test 9: Exclusive modes do not include llm-security/output-sanitization"
for mode in discover deploy opensource content; do
  mode_lenses="$(jq -r --arg mode "$mode" \
    '.domains | sort_by(.order)[] | (if $mode == "discover" then select(.mode == "discover") elif $mode == "deploy" then select(.mode == "deploy") elif $mode == "opensource" then select(.mode == "opensource") elif $mode == "content" then select(.mode == "content") else select(.mode != "discover" and .mode != "deploy" and .mode != "opensource" and .mode != "content") end) | .id as $d | .lenses[] | $d + "/" + .' "$DOMAINS_FILE")"
  if grep -qxF "llm-security/output-sanitization" <<< "$mode_lenses"; then
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: $mode mode should not include llm-security/output-sanitization"
  else
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  PASS: $mode mode excludes llm-security/output-sanitization"
  fi
done

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
