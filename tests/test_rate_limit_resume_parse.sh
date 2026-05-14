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

# Unit tests for parse_rate_limit_resume_epoch in lib/streak.sh.
# These define the public helper contract for issue #115: parse a bounded
# resume time from agent rate-limit output and print a Unix epoch, or print
# nothing when no usable resume time exists.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/streak.sh"

export TZ=UTC

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures/agent-rate-limits"

write_fixture() {
  local name="$1" body="$2"
  local file="$TMPDIR/$name.txt"
  printf '%b\n' "$body" > "$file"
  printf '%s\n' "$file"
}

parse_epoch() {
  local file="$1"
  parse_rate_limit_resume_epoch "$file" 2>/dev/null || true
}

assert_epoch_eq() {
  local desc="$1" file="$2" expected="$3"
  TOTAL=$((TOTAL + 1))

  local actual
  actual="$(parse_epoch "$file")"
  if [[ "$actual" =~ ^[0-9]+$ && "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='${actual:-<empty>}')"
  fi
}

assert_epoch_between_offset() {
  local desc="$1" file="$2" offset="$3"
  TOTAL=$((TOTAL + 1))

  local before after actual min max
  before="$(date +%s)"
  actual="$(parse_epoch "$file")"
  after="$(date +%s)"
  min=$((before + offset))
  max=$((after + offset + 2))

  if [[ "$actual" =~ ^[0-9]+$ && "$actual" -ge "$min" && "$actual" -le "$max" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected ${min}..${max}, actual='${actual:-<empty>}')"
  fi
}

assert_empty() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))

  local actual
  actual="$(parse_epoch "$file")"
  if [[ -z "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected empty, actual='$actual')"
  fi
}

expected_next_time_epoch() {
  local zone="$1" time_expr="$2"
  local expected now

  expected="$(TZ="$zone" date -d "$time_expr" +%s)"
  now="$(date +%s)"
  if [[ "$expected" -le "$now" ]]; then
    expected=$((expected + 86400))
  fi
  printf '%s\n' "$expected"
}

echo "=== parse_rate_limit_resume_epoch - absolute formats ==="

f="$(write_fixture "incident-ordinal" "ERROR: You've hit your usage limit. Try again at Apr 16th, 2026 12:04 AM.")"
expected="$(date -d "Apr 16, 2026 12:04 AM" +%s)"
assert_epoch_eq "Incident format with ordinal day suffix" "$f" "$expected"

f="$(write_fixture "iso-utc" "Rate limited. Try again at 2026-04-16 00:04:00 UTC.")"
expected="$(date -d "2026-04-16 00:04:00 UTC" +%s)"
assert_epoch_eq "ISO-like absolute timestamp with timezone" "$f" "$expected"

f="$(write_fixture "time-only-tz" "ERROR: usage limit reached. Try again at 12:04 AM PDT.")"
now="$(date +%s)"
expected="$(date -d "12:04 AM PDT" +%s)"
if [[ "$expected" -le "$now" ]]; then
  expected=$((expected + 86400))
fi
assert_epoch_eq "Time-only timestamp rolls forward to the next occurrence" "$f" "$expected"

echo ""
echo "=== parse_rate_limit_resume_epoch - resets formats ==="

old_tz="${TZ:-}"
export TZ=America/Los_Angeles

expected="$(expected_next_time_epoch "Europe/Berlin" "11:30 PM")"
assert_epoch_eq "Paren-wrapped IANA zone honored, not host-TZ-shadowed" "$FIXTURE_DIR/claude-user-tier-2026-05.txt" "$expected"

expected="$(expected_next_time_epoch "UTC" "23:30")"
assert_epoch_eq "Paren-wrapped UTC zone honored" "$FIXTURE_DIR/claude-user-tier-utc.txt" "$expected"

f="$(write_fixture "claude-resets-ansi-spaced-ampm" $'\e[1;31mYou'\''ve hit your limit · resets 11:30 PM (Europe/Berlin)\e[0m')"
expected="$(expected_next_time_epoch "Europe/Berlin" "11:30 PM")"
assert_epoch_eq "ANSI-wrapped reset time with spaced AM/PM parses" "$f" "$expected"

f="$(write_fixture "claude-resets-no-tz" "You've hit your limit · resets 11pm")"
expected="$(expected_next_time_epoch "America/Los_Angeles" "11 PM")"
assert_epoch_eq "Reset time without zone uses host timezone and rolls forward" "$f" "$expected"

expected="$(expected_next_time_epoch "America/Los_Angeles" "12:04 AM")"
assert_epoch_eq "Reset time with colon and spaced AM/PM uses host timezone" "$FIXTURE_DIR/claude-user-tier-am.txt" "$expected"

f="$(write_fixture "claude-resets-vague" "You've hit your limit · resets soon")"
assert_empty "Vague resets wording remains unparseable" "$f"

export TZ="$old_tz"

echo ""
echo "=== parse_rate_limit_resume_epoch - relative formats ==="

f="$(write_fixture "retry-after" "HTTP 429: Retry-After: 90 seconds")"
assert_epoch_between_offset "HTTP Retry-After seconds" "$f" 90

f="$(write_fixture "retry-after-text" "retry after 90 seconds")"
assert_epoch_between_offset "Space-separated retry after seconds" "$f" 90

f="$(write_fixture "minutes" "ERROR: rate limit reached. Try again in 45 minutes.")"
assert_epoch_between_offset "Try again in minutes" "$f" 2700

f="$(write_fixture "hours-minutes" "ERROR: rate-limited. Try again in 2h 30m.")"
assert_epoch_between_offset "Try again in shorthand hours and minutes" "$f" 9000

f="$(write_fixture "long-hours-minutes" "ERROR: rate-limited. Try again in 2 hours 30 minutes.")"
assert_epoch_between_offset "Try again in long-form hours and minutes" "$f" 9000

f="$(write_fixture "ansi" $'\e[1;31mERROR: rate limit reached. Try again in 10 seconds.\e[0m')"
assert_epoch_between_offset "ANSI-wrapped rate-limit line" "$f" 10

echo ""
echo "=== parse_rate_limit_resume_epoch - negative fixtures ==="

f="$(write_fixture "no-time" "ERROR: usage limit reached. Try again later.")"
assert_empty "Rate-limit output without a parseable time" "$f"

f="$(write_fixture "malformed" "ERROR: rate limit reached. Try again at soon-ish o'clock.")"
assert_empty "Malformed absolute time" "$f"

f="$(write_fixture "unrelated" "Analysis complete. No rate-limit resume time here.\nDONE")"
assert_empty "Unrelated successful output" "$f"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
