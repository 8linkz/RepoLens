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

# Contract for issue #137:
#   1. lib/core.sh exposes a declarative MODE_DEFAULT_DEPTH table.
#   2. mode_default_depth <mode> returns the default DONE depth for each mode.
#   3. repolens.sh consumes the resolver and keeps --max-issues as a separate
#      effective-depth override after the mode default lookup.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$SCRIPT_DIR/lib/core.sh"
REPO="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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

assert_match() {
  local desc="$1" file="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    pass_with "$desc"
  else
    fail_with "$desc" "Pattern not found: $pattern"
  fi
}

assert_not_match() {
  local desc="$1" file="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    fail_with "$desc" "Unexpected pattern found: $pattern"
  else
    pass_with "$desc"
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

assert_max_issues_override_after_default_lookup() {
  local resolver_line max_if_line max_assign_line

  resolver_line="$(
    grep -nE 'DONE_STREAK_REQUIRED=.*mode_default_depth[[:space:]]+"?\$MODE"?' "$REPO" \
      | head -1 \
      | cut -d: -f1
  )"

  read -r max_if_line max_assign_line < <(
    awk '
      /if \[\[ -n "\$MAX_ISSUES" \]\]; then/ { in_max=NR; next }
      in_max && /DONE_STREAK_REQUIRED=1/ { print in_max, NR; exit }
      in_max && /fi/ { in_max=0 }
    ' "$REPO"
  )

  TOTAL=$((TOTAL + 1))
  if [[ "$resolver_line" =~ ^[0-9]+$ \
      && "$max_if_line" =~ ^[0-9]+$ \
      && "$max_assign_line" =~ ^[0-9]+$ \
      && "$resolver_line" -lt "$max_if_line" \
      && "$max_if_line" -lt "$max_assign_line" ]]; then
    pass_with "repolens.sh applies --max-issues override after mode default lookup"
  else
    fail_with \
      "repolens.sh applies --max-issues override after mode default lookup" \
      "resolver_line=${resolver_line:-missing} max_if_line=${max_if_line:-missing} max_assign_line=${max_assign_line:-missing}"
  fi
}

collect_repolens_mode_validation_modes() {
  awk '
    /# --- Validate mode ---/ { seen_validation=1; next }
    seen_validation && /case "\$MODE" in/ { in_mode_case=1; next }
    in_mode_case && /^[[:space:]]*\*\)/ { exit }
    in_mode_case && /\)[[:space:]]*;;/ {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*\)[[:space:]]*;;.*/, "", line)
      split(line, modes, /\|/)
      for (i in modes) {
        if (modes[i] != "") {
          print modes[i]
        }
      }
    }
  ' "$REPO" | sort -u
}

assert_depth_table_matches_mode_validation() {
  local mode missing_text extra_text
  local -a validation_modes=()
  local -a missing=()
  local -a extra=()
  local -A validation_lookup=()

  mapfile -t validation_modes < <(collect_repolens_mode_validation_modes)

  for mode in "${validation_modes[@]}"; do
    validation_lookup["$mode"]=1
    if [[ -z "${MODE_DEFAULT_DEPTH[$mode]+set}" ]]; then
      missing+=("$mode")
    fi
  done

  for mode in "${!MODE_DEFAULT_DEPTH[@]}"; do
    if [[ -z "${validation_lookup[$mode]:-}" ]]; then
      extra+=("$mode")
    fi
  done

  TOTAL=$((TOTAL + 1))
  if [[ "${#validation_modes[@]}" -eq 0 ]]; then
    fail_with \
      "MODE_DEFAULT_DEPTH covers every accepted CLI mode" \
      "Could not parse the mode-validation case block in repolens.sh"
  elif [[ "${#missing[@]}" -eq 0 && "${#extra[@]}" -eq 0 ]]; then
    pass_with "MODE_DEFAULT_DEPTH covers every accepted CLI mode"
  else
    missing_text="${missing[*]:-none}"
    extra_text="${extra[*]:-none}"
    fail_with \
      "MODE_DEFAULT_DEPTH covers every accepted CLI mode" \
      "Missing table entries: $missing_text | Unsupported table entries: $extra_text"
  fi
}

assert_done_threshold_block_has_no_mode_dispatch() {
  local block
  block="$(
    awk '
      /# --- Derive DONE streak threshold ---/ { in_block=1; next }
      in_block && /# --- Safety cap:/ { exit }
      in_block { print }
    ' "$REPO"
  )"

  TOTAL=$((TOTAL + 1))
  if [[ -z "$block" ]]; then
    fail_with \
      "DONE streak derivation is table-driven, not mode-dispatch-driven" \
      "Could not find the DONE streak derivation block"
  elif [[ "$block" == *'mode_default_depth "$MODE"'* ]] \
      && ! grep -Eq 'case[[:space:]]+"?\$MODE|(\$MODE|MODE).*==.*(audit|feature|bugfix|custom|discover|deploy|opensource|content)' <<<"$block"; then
    pass_with "DONE streak derivation is table-driven, not mode-dispatch-driven"
  else
    fail_with \
      "DONE streak derivation is table-driven, not mode-dispatch-driven" \
      "Derivation block should use mode_default_depth without inline mode comparisons: $block"
  fi
}

echo "=== Test Suite: per-mode default depth ==="

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
else
  fail_with "lib/core.sh exposes MODE_DEFAULT_DEPTH" "Missing associative default table"
  echo "  SKIP: MODE_DEFAULT_DEPTH entry checks wait for the table"
fi

if declare -p MODE_DEFAULT_DEPTH >/dev/null 2>&1; then
  assert_depth_table_matches_mode_validation
else
  echo "  SKIP: mode validation sync waits for MODE_DEFAULT_DEPTH"
fi

echo ""
echo "=== mode_default_depth resolver ==="

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
    assert_eq "mode_default_depth $mode returns $expected" "$expected" "$(mode_default_depth "$mode")"
  done

  unknown_stdout="$TMPDIR/unknown.out"
  unknown_stderr="$TMPDIR/unknown.err"
  ( mode_default_depth "__not_a_mode__" ) >"$unknown_stdout" 2>"$unknown_stderr"
  unknown_rc=$?
  TOTAL=$((TOTAL + 1))
  if [[ "$unknown_rc" -ne 0 ]] && grep -q "unsupported mode '__not_a_mode__'" "$unknown_stderr"; then
    pass_with "mode_default_depth rejects unsupported modes with a clear error"
  else
    fail_with \
      "mode_default_depth rejects unsupported modes with a clear error" \
      "rc=$unknown_rc stderr=$(cat "$unknown_stderr")"
  fi
else
  echo "  SKIP: resolver matrix waits for mode_default_depth"
fi

echo ""
echo "=== repolens.sh integration contract ==="

assert_match \
  "repolens.sh initializes DONE_STREAK_REQUIRED via mode_default_depth" \
  "$REPO" \
  'DONE_STREAK_REQUIRED=.*mode_default_depth[[:space:]]+"?\$MODE"?'

assert_max_issues_override_after_default_lookup

assert_done_threshold_block_has_no_mode_dispatch

assert_not_match \
  "repolens.sh no longer embeds the old single-pass mode comparison chain" \
  "$REPO" \
  'MODE.*discover.*MODE.*deploy.*MODE.*custom.*MODE.*opensource.*MODE.*content'

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
