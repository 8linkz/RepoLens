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

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/template.sh"

PASS=0
FAIL=0
TOTAL=0

pass_with() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail_with() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && printf '    %s\n' "$2"; }

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Missing: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Unexpected: $needle"
  fi
}

assert_matches() {
  local desc="$1" pattern="$2" haystack="$3" flattened
  flattened="${haystack//$'\n'/ }"
  TOTAL=$((TOTAL + 1))
  if printf '%s\n' "$flattened" | grep -Eiq -- "$pattern"; then
    pass_with "$desc"
  else
    fail_with "$desc" "Pattern did not match: $pattern"
  fi
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
  (( FAIL == 0 )) || exit 1
}

extract_min_severity_section() {
  awk '
    /^## Minimum Severity$/ { capture = 1 }
    capture { print }
    /^### Issue Sizing/ { exit }
  '
}

echo "=== content min-severity split prompt fixture ==="

base_file="$SCRIPT_DIR/prompts/_base/content.md"
lens_file="$SCRIPT_DIR/prompts/lenses/content-quality/topic-extraction.md"
base_vars=""
base_vars+="PROJECT_PATH=/tmp/repolens-content-fixture"
base_vars+="|DOMAIN=content-quality"
base_vars+="|DOMAIN_NAME=Content Quality"
base_vars+="|DOMAIN_COLOR=5ab0ff"
base_vars+="|LENS_ID=topic-extraction"
base_vars+="|LENS_NAME=Topic Extraction & Issue Generation"
base_vars+="|LENS_LABEL=content:content-quality/topic-extraction"
base_vars+="|RUN_ID=test-content-min-severity"
base_vars+="|REPO_NAME=fixture-repo"
base_vars+="|REPO_OWNER=fixture-owner"
base_vars+="|FORGE_REPO_SLUG=fixture-owner/fixture-repo"
base_vars+="|FORGE_ISSUE_CREATE=fake-forge issue create --repo fixture-owner/fixture-repo"
base_vars+="|FORGE_LABEL_CREATE=fake-forge label create content:content-quality/topic-extraction"
base_vars+="|FORGE_ENHANCEMENT_LABEL_CREATE=fake-forge label create enhancement"
base_vars+="|FORGE_ISSUE_LIST_OPEN=fake-forge issue list --state open"
base_vars+="|FORGE_ISSUE_LIST_CLOSED=fake-forge issue list --state closed"
vars="${base_vars}|MODE=content|MIN_SEVERITY=high"

rendered="$(compose_prompt "$base_file" "$lens_file" "$vars" "" "content")"
min_section="$(printf '%s\n' "$rendered" | extract_min_severity_section)"

assert_contains "renders minimum severity section" "## Minimum Severity" "$min_section"
assert_contains "section names the high threshold" "**high**" "$min_section"
assert_matches "section applies threshold to content audit findings" \
  "(content[ -])?audit findings?.*(severity|severit(y|ies))|severity.*(content[ -])?audit findings?" \
  "$min_section"
assert_matches "section keeps critical and high audit findings eligible" \
  "\\[CRITICAL\\].*\\[HIGH\\]|\\[HIGH\\].*\\[CRITICAL\\]" \
  "$min_section"
assert_matches "section skips medium and low audit findings below high" \
  "(skip|exclude|below).*\\[MEDIUM\\].*\\[LOW\\]|\\[MEDIUM\\].*\\[LOW\\].*(skip|exclude|below)" \
  "$min_section"
assert_matches "section lists all proposal priority titles" \
  "\\[P0\\].*\\[P1\\].*\\[P2\\].*\\[P3\\]" \
  "$min_section"
assert_matches "section says proposal priorities are not severities" \
  "(priority|priorities|priority-ranked).*(not|non[- ]).*severit(y|ies|y-ranked)|(not|non[- ]).*severit(y|ies|y-ranked).*(priority|priorities|priority-ranked)" \
  "$min_section"
assert_matches "section preserves priority proposals under min severity" \
  "(remain|preserv|valid).*\\[P0\\].*\\[P1\\].*\\[P2\\].*\\[P3\\]|\\[P0\\].*\\[P1\\].*\\[P2\\].*\\[P3\\].*(remain|preserv|valid)" \
  "$min_section"
assert_matches "section does not drop or warn priority proposals for non-severity metadata" \
  "(do not|must not|not).*(warn|drop|skip|invalid).*(priority|proposal|non[- ]severity)|(priority|proposal|non[- ]severity).*(do not|must not|not).*(warn|drop|skip|invalid)" \
  "$min_section"
assert_not_contains "rendered prompt has no raw min severity placeholder" "{{MIN_SEVERITY_SECTION}}" "$rendered"

assert_content_threshold() {
  local min_level="$1" eligible_titles="$2" skipped_titles="$3"
  local threshold_rendered threshold_section

  threshold_rendered="$(compose_prompt "$base_file" "$lens_file" "${base_vars}|MODE=content|MIN_SEVERITY=${min_level}" "" "content")"
  threshold_section="$(printf '%s\n' "$threshold_rendered" | extract_min_severity_section)"

  assert_contains "content ${min_level} keeps expected audit titles" \
    "create issues only for ${eligible_titles} audit findings" \
    "$threshold_section"

  if [[ -n "$skipped_titles" ]]; then
    assert_contains "content ${min_level} skips expected audit titles" \
      "Skip ${skipped_titles} audit findings below this threshold" \
      "$threshold_section"
  else
    assert_contains "content ${min_level} has no below-threshold audit titles" \
      "No audit severity titles are below this threshold." \
      "$threshold_section"
  fi
}

assert_content_threshold "critical" "[CRITICAL]" "[HIGH], [MEDIUM], and [LOW]"
assert_content_threshold "medium" "[CRITICAL], [HIGH], and [MEDIUM]" "[LOW]"
assert_content_threshold "low" "[CRITICAL], [HIGH], [MEDIUM], and [LOW]" ""

audit_rendered="$(compose_prompt "$SCRIPT_DIR/prompts/_base/audit.md" "$lens_file" "${base_vars}|MODE=audit|MIN_SEVERITY=high" "" "audit")"
audit_min_section="$(printf '%s\n' "$audit_rendered" | extract_min_severity_section)"

assert_contains "audit mode keeps generic min-severity wording" \
  "Only create issues for findings whose severity is **high** or higher." \
  "$audit_min_section"
assert_contains "audit mode keeps generic severity order" \
  "critical > high > medium > low" \
  "$audit_min_section"
assert_not_contains "audit mode does not include content proposal priorities" \
  "[P0]" \
  "$audit_min_section"
assert_not_contains "audit mode does not describe proposal priority exceptions" \
  "proposal priorities" \
  "$audit_min_section"

finish
