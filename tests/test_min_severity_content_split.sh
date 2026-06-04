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
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/template.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/synthesize.sh"

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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected '$expected', got '$actual'"
  fi
}

assert_success() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected exit 0, got $actual"
  fi
}

assert_failure() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit"
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

TMP_PARENT="$SCRIPT_DIR/logs/test-min-severity-content-split"
mkdir -p "$TMP_PARENT"
TEST_TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
cleanup() {
  rm -rf "$TEST_TMPDIR"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

print_content_synthesizer_manifest_fixture() {
  cat <<'JSON'
[
  {
    "cluster_id": "content-critical::kept",
    "title": "[CRITICAL] Fix broken canonical links",
    "severity": "critical",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-integrity",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "Critical audit body"
  },
  {
    "cluster_id": "content-high::kept",
    "title": "[HIGH] Repair missing article outline",
    "severity": "high",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-structure",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "High audit body"
  },
  {
    "cluster_id": "content-medium::dropped",
    "title": "[MEDIUM] Clarify archive teaser copy",
    "severity": "medium",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-polish",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "Medium audit body"
  },
  {
    "cluster_id": "content-low::dropped",
    "title": "[LOW] Polish tag label casing",
    "severity": "low",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-polish",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "Low audit body"
  },
  {
    "cluster_id": "proposal-p0::kept",
    "title": "[P0] Publish migration guide",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-proposal",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content", "enhancement"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "P0 proposal body"
  },
  {
    "cluster_id": "proposal-p1::kept",
    "title": "[P1] Add editorial calendar",
    "severity": "priority",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-proposal",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content", "enhancement"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "P1 proposal body"
  },
  {
    "cluster_id": "proposal-p2::kept",
    "title": "[P2] Refresh onboarding examples",
    "severity": "low",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-proposal",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content", "enhancement"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "P2 proposal body"
  },
  {
    "cluster_id": "proposal-p3::kept",
    "title": "[P3] Add glossary sidebar",
    "severity": "not-applicable",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-proposal",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content", "enhancement"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "P3 proposal body"
  },
  {
    "cluster_id": "audit-high-missing-severity::dropped",
    "title": "[HIGH] Missing severity content audit",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-integrity",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "Missing severity audit body"
  },
  {
    "cluster_id": "audit-critical-invalid-severity::dropped",
    "title": "[CRITICAL] Invalid severity content audit",
    "severity": "urgent",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-integrity",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "Invalid severity audit body"
  }
]
JSON
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

echo ""
echo "=== content synthesizer min-severity manifest fixture ==="

content_manifest="$TEST_TMPDIR/content-manifest.json"
print_content_synthesizer_manifest_fixture > "$content_manifest"

export MODE=content
export REPOLENS_MODE=content
_synthesize_filter_manifest_min_severity "$content_manifest" high 2>"$TEST_TMPDIR/content-filter.err"
filter_status=$?
filter_errors="$(cat "$TEST_TMPDIR/content-filter.err")"
filtered_ids="$(jq -r 'map(.cluster_id) | join(",")' "$content_manifest" 2>/dev/null || true)"

assert_success "content manifest filter returns success" "$filter_status"
assert_eq "content high threshold keeps critical/high audit entries and all priority proposals" \
  "content-critical::kept,content-high::kept,proposal-p0::kept,proposal-p1::kept,proposal-p2::kept,proposal-p3::kept" \
  "$filtered_ids"
assert_not_contains "content filter drops medium audit entry" \
  "content-medium::dropped" \
  "$filtered_ids"
assert_not_contains "content filter drops low audit entry" \
  "content-low::dropped" \
  "$filtered_ids"
assert_not_contains "content filter drops missing-severity audit entry" \
  "audit-high-missing-severity::dropped" \
  "$filtered_ids"
assert_not_contains "content filter drops invalid-severity audit entry" \
  "audit-critical-invalid-severity::dropped" \
  "$filtered_ids"
assert_matches "content filter warns about missing severity audit entries" \
  "(missing severity|invalid severity).*Missing severity content audit|Missing severity content audit.*(missing severity|invalid severity)" \
  "$filter_errors"
assert_matches "content filter warns about invalid severity audit entries" \
  "invalid severity.*Invalid severity content audit|Invalid severity content audit.*invalid severity" \
  "$filter_errors"
assert_not_contains "content filter does not warn about P0 missing severity proposal" \
  "[P0] Publish migration guide" \
  "$filter_errors"
assert_not_contains "content filter does not warn about P1 non-severity proposal metadata" \
  "[P1] Add editorial calendar" \
  "$filter_errors"
assert_not_contains "content filter does not warn about P3 non-severity proposal metadata" \
  "[P3] Add glossary sidebar" \
  "$filter_errors"

mode_only_manifest="$TEST_TMPDIR/content-mode-only-manifest.json"
print_content_synthesizer_manifest_fixture > "$mode_only_manifest"
unset REPOLENS_MODE
export MODE=content
_synthesize_filter_manifest_min_severity "$mode_only_manifest" high 2>"$TEST_TMPDIR/content-mode-only-filter.err"
mode_only_status=$?
mode_only_ids="$(jq -r 'map(.cluster_id) | join(",")' "$mode_only_manifest" 2>/dev/null || true)"

assert_success "MODE=content alone activates content min-severity filtering" "$mode_only_status"
assert_eq "MODE=content alone preserves priority proposals" \
  "content-critical::kept,content-high::kept,proposal-p0::kept,proposal-p1::kept,proposal-p2::kept,proposal-p3::kept" \
  "$mode_only_ids"

repolens_mode_only_manifest="$TEST_TMPDIR/content-repolens-mode-only-manifest.json"
print_content_synthesizer_manifest_fixture > "$repolens_mode_only_manifest"
unset MODE
export REPOLENS_MODE=content
_synthesize_filter_manifest_min_severity "$repolens_mode_only_manifest" high 2>"$TEST_TMPDIR/content-repolens-mode-only-filter.err"
repolens_mode_only_status=$?
repolens_mode_only_ids="$(jq -r 'map(.cluster_id) | join(",")' "$repolens_mode_only_manifest" 2>/dev/null || true)"

assert_success "REPOLENS_MODE=content alone activates content min-severity filtering" "$repolens_mode_only_status"
assert_eq "REPOLENS_MODE=content alone preserves priority proposals" \
  "content-critical::kept,content-high::kept,proposal-p0::kept,proposal-p1::kept,proposal-p2::kept,proposal-p3::kept" \
  "$repolens_mode_only_ids"

export MODE=content
export REPOLENS_MODE=content

echo ""
echo "=== content run_synthesizer min-severity fixture ==="

PROJECT_PATH="$TEST_TMPDIR/project"
mkdir -p "$PROJECT_PATH"
export AGENT=claude
export PROJECT_PATH

content_run_id="run-content-min-filter"
RUN_LOG="$TEST_TMPDIR/$content_run_id-logs/$content_run_id"
mkdir -p "$RUN_LOG/rounds/round-1/lens-outputs/content-quality"
printf 'content finding fixture\n' > "$RUN_LOG/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"
export LOG_BASE="$RUN_LOG"
export REPOLENS_MIN_SEVERITY=high

compose_prompt() {
  printf 'STUBBED CONTENT SYNTHESIZER PROMPT'
}

run_agent() {
  print_content_synthesizer_manifest_fixture
  printf 'DONE\n'
}

run_synthesizer "$content_run_id" 2>"$TEST_TMPDIR/content-run.err"
run_status=$?
run_errors="$(cat "$TEST_TMPDIR/content-run.err")"
run_ids="$(jq -r 'map(.cluster_id) | join(",")' "$RUN_LOG/final/manifest.json" 2>/dev/null || true)"

unset REPOLENS_MIN_SEVERITY LOG_BASE MODE REPOLENS_MODE

assert_success "content run_synthesizer accepts fake agent output with priority proposal metadata" "$run_status"
assert_eq "content run_synthesizer promotes only eligible audit entries plus all proposals" \
  "content-critical::kept,content-high::kept,proposal-p0::kept,proposal-p1::kept,proposal-p2::kept,proposal-p3::kept" \
  "$run_ids"
assert_not_contains "content run_synthesizer does not reject P0 missing severity as schema-invalid" \
  "proposal-p0::kept" \
  "$run_errors"
assert_not_contains "content run_synthesizer does not reject P1 priority severity as schema-invalid" \
  "proposal-p1::kept" \
  "$run_errors"

echo ""
echo "=== content validate_manifest proposal severity exception ==="

content_proposal_manifest="$TEST_TMPDIR/content-proposal-validate.json"
print_content_synthesizer_manifest_fixture |
  jq '[.[] | select(.cluster_id == "proposal-p0::kept")]' > "$content_proposal_manifest"

export MODE=content
export REPOLENS_MODE=content
validate_manifest "$content_proposal_manifest" 2>"$TEST_TMPDIR/content-proposal-validate.err"
proposal_validate_status=$?
proposal_validate_errors="$(cat "$TEST_TMPDIR/content-proposal-validate.err")"

assert_success "content validate_manifest accepts P0 proposal without severity" "$proposal_validate_status"
assert_not_contains "content validate_manifest does not mark P0 proposal severity invalid" \
  "invalid severity" \
  "$proposal_validate_errors"

non_content_proposal_manifest="$TEST_TMPDIR/non-content-proposal-validate.json"
print_content_synthesizer_manifest_fixture |
  jq '[.[] | select(.cluster_id == "proposal-p0::kept")]' > "$non_content_proposal_manifest"

unset MODE REPOLENS_MODE
validate_manifest "$non_content_proposal_manifest" 2>"$TEST_TMPDIR/non-content-proposal-validate.err"
non_content_validate_status=$?
non_content_validate_errors="$(cat "$TEST_TMPDIR/non-content-proposal-validate.err")"

assert_failure "non-content validate_manifest still rejects P0 proposal without severity" "$non_content_validate_status"
assert_contains "non-content rejection mentions invalid severity" \
  "invalid severity" \
  "$non_content_validate_errors"

content_audit_missing_manifest="$TEST_TMPDIR/content-audit-missing-validate.json"
print_content_synthesizer_manifest_fixture |
  jq '[.[] | select(.cluster_id == "audit-high-missing-severity::dropped")]' > "$content_audit_missing_manifest"

export MODE=content
export REPOLENS_MODE=content
validate_manifest "$content_audit_missing_manifest" 2>"$TEST_TMPDIR/content-audit-missing-validate.err"
audit_missing_validate_status=$?
audit_missing_validate_errors="$(cat "$TEST_TMPDIR/content-audit-missing-validate.err")"

assert_failure "content validate_manifest still rejects audit entries without severity" "$audit_missing_validate_status"
assert_contains "content audit rejection mentions invalid severity" \
  "invalid severity" \
  "$audit_missing_validate_errors"

echo ""
echo "=== content min-severity cross-link sidecar fixture ==="

content_cross_link_manifest="$TEST_TMPDIR/content-cross-link-manifest.json"
content_cross_link_verification="$TEST_TMPDIR/content-cross-link-verification.json"

cat > "$content_cross_link_manifest" <<'JSON'
[
  {
    "cluster_id": "proposal-p2-cross-link::kept",
    "title": "[P2] Refresh onboarding examples",
    "severity": "low",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-proposal",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content", "enhancement"],
    "cross_link_actions": [
      {
        "type": "comment",
        "issue_number": 77,
        "body": "A priority proposal that remains in the manifest must not also be preserved as filtered evidence."
      }
    ],
    "granularity": "independent",
    "body": "P2 proposal body"
  },
  {
    "cluster_id": "content-low-cross-link::dropped",
    "title": "[LOW] Polish tag label casing",
    "severity": "low",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-polish",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/tag-polish.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content"],
    "cross_link_actions": [
      {
        "type": "comment",
        "issue_number": 88,
        "body": "Below-threshold content audit evidence should still be preserved for existing issues."
      }
    ],
    "granularity": "independent",
    "body": "Low audit body"
  },
  {
    "cluster_id": "content-missing-severity-cross-link::dropped",
    "title": "[HIGH] Missing severity cross-link audit",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-structure",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/missing-severity.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content"],
    "cross_link_actions": [
      {
        "type": "comment",
        "issue_number": 99,
        "body": "Missing-severity audit evidence must not be preserved as filtered evidence."
      }
    ],
    "granularity": "independent",
    "body": "Missing severity audit body"
  },
  {
    "cluster_id": "content-invalid-severity-cross-link::dropped",
    "title": "[CRITICAL] Invalid severity cross-link audit",
    "severity": "urgent",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-structure",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/invalid-severity.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content"],
    "cross_link_actions": [
      {
        "type": "comment",
        "issue_number": 100,
        "body": "Invalid-severity audit evidence must not be preserved as filtered evidence."
      }
    ],
    "granularity": "independent",
    "body": "Invalid severity audit body"
  },
  {
    "cluster_id": "content-high-cross-link::kept",
    "title": "[HIGH] Repair missing article outline",
    "severity": "high",
    "domain": "content-quality",
    "lens": "topic-extraction",
    "root_cause_category": "content-structure",
    "source_finding_paths": ["logs/run-content/rounds/round-1/lens-outputs/content-quality/outline.md"],
    "dedup_against_existing": [],
    "proposed_labels": ["content"],
    "cross_link_actions": [],
    "granularity": "independent",
    "body": "High audit body"
  }
]
JSON

cat > "$content_cross_link_verification" <<'JSON'
[
  {
    "source_finding_path": "logs/run-content/rounds/round-1/lens-outputs/content-quality/topic-extraction.md",
    "status": "RIGHT"
  },
  {
    "source_finding_path": "logs/run-content/rounds/round-1/lens-outputs/content-quality/tag-polish.md",
    "status": "RIGHT"
  },
  {
    "source_finding_path": "logs/run-content/rounds/round-1/lens-outputs/content-quality/missing-severity.md",
    "status": "RIGHT"
  },
  {
    "source_finding_path": "logs/run-content/rounds/round-1/lens-outputs/content-quality/invalid-severity.md",
    "status": "RIGHT"
  },
  {
    "source_finding_path": "logs/run-content/rounds/round-1/lens-outputs/content-quality/outline.md",
    "status": "RIGHT"
  }
]
JSON

_synthesize_filter_manifest_min_severity "$content_cross_link_manifest" high "$content_cross_link_verification" 2>"$TEST_TMPDIR/content-cross-link-filter.err"
cross_link_filter_status=$?
content_cross_link_ids="$(jq -r 'map(.cluster_id) | join(",")' "$content_cross_link_manifest" 2>/dev/null || true)"
content_cross_link_sidecar="$TEST_TMPDIR/cross-link-actions.preserved.json"

unset MODE REPOLENS_MODE

assert_success "content cross-link filter returns success" "$cross_link_filter_status"
assert_eq "content cross-link filter keeps priority proposal and high audit entry" \
  "proposal-p2-cross-link::kept,content-high-cross-link::kept" \
  "$content_cross_link_ids"
assert_eq "content cross-link sidecar preserves only dropped audit comment" \
  "88" \
  "$(jq -r 'map(.issue_number) | join(",")' "$content_cross_link_sidecar")"
assert_eq "content cross-link sidecar does not duplicate kept priority proposal comment" \
  "false" \
  "$(jq 'any(.issue_number == 77)' "$content_cross_link_sidecar")"
assert_eq "content cross-link sidecar drops missing-severity audit comment" \
  "false" \
  "$(jq 'any(.issue_number == 99)' "$content_cross_link_sidecar")"
assert_eq "content cross-link sidecar drops invalid-severity audit comment" \
  "false" \
  "$(jq 'any(.issue_number == 100)' "$content_cross_link_sidecar")"

finish
