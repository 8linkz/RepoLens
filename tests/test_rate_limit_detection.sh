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

# Unit tests for detect_agent_rate_limit in lib/streak.sh
# Covers documented agent rate-limit signatures plus ANSI,
# case-insensitive, and negative (benign transcript) fixtures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/streak.sh"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures/agent-rate-limits"

assert_detect() {
  local desc="$1" file="$2" expected="$3"
  TOTAL=$((TOTAL + 1))
  local actual
  if detect_agent_rate_limit "$file" >/dev/null; then
    actual="yes"
  else
    actual="no"
  fi
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected=$expected actual=$actual)"
  fi
}

assert_output_contains_pipe() {
  local desc="$1" file="$2"
  TOTAL=$((TOTAL + 1))
  local output
  output="$(detect_agent_rate_limit "$file" 2>/dev/null || true)"
  if [[ "$output" == *"|"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (output='$output')"
  fi
}

echo "=== detect_agent_rate_limit — positive signatures ==="

if [[ -d "$FIXTURE_DIR" ]]; then
  while IFS= read -r fixture; do
    assert_detect "positive fixture: ${fixture##*/}" "$fixture" "yes"
  done < <(find "$FIXTURE_DIR" -maxdepth 1 -type f -name '*.txt' -print | sort)
fi

# Signature 1: "You've hit your usage limit" (exact incident text)
f="$TMPDIR/sig1.txt"
printf "ERROR: You've hit your usage limit. To get more access now, send a request to your\nadmin or try again at Apr 16th, 2026 12:04 AM.\n" > "$f"
assert_detect "'You've hit your usage limit' (straight quote) — incident text" "$f" "yes"

# Signature 1b: curly/typographic apostrophe variant
f="$TMPDIR/sig1b.txt"
printf "ERROR: You\xe2\x80\x99ve hit your usage limit. Please upgrade your plan.\n" > "$f"
assert_detect "'You\xe2\x80\x99ve hit your usage limit' (curly apostrophe)" "$f" "yes"

# Signature 2: "usage limit"
f="$TMPDIR/sig2.txt"
printf "ERROR: usage limit exceeded for this organization.\n" > "$f"
assert_detect "'usage limit' (generic)" "$f" "yes"

f="$TMPDIR/sig2b.txt"
printf "ERROR: usage limit reached for this organization.\n" > "$f"
assert_detect "'usage limit reached'" "$f" "yes"

f="$TMPDIR/sig2c.txt"
printf "ERROR: usage limit hit for this organization.\n" > "$f"
assert_detect "'usage limit hit'" "$f" "yes"

# Signature 3: "rate limit" variants
f="$TMPDIR/sig3a.txt"
printf "ERROR: rate limit reached, try again in 5 minutes\n" > "$f"
assert_detect "'ERROR: rate limit reached'" "$f" "yes"

f="$TMPDIR/sig3b.txt"
printf "Request was rate-limited until 2026-04-16T00:04:00Z\n" > "$f"
assert_detect "'rate-limited' with hyphen" "$f" "yes"

f="$TMPDIR/sig3c.txt"
printf "HTTP 429: Retry-After: 90 seconds\n" > "$f"
assert_detect "'HTTP 429' provider throttling response" "$f" "yes"

f="$TMPDIR/sig3c_http11.txt"
printf "HTTP/1.1 429 Too Many Requests\nRetry-After: 90\n" > "$f"
assert_detect "'HTTP/1.1 429' provider throttling response" "$f" "yes"

f="$TMPDIR/sig3d.txt"
printf "RateLimitError: retry budget exhausted\n" > "$f"
assert_detect "'RateLimitError' provider exception" "$f" "yes"

# Signature 4: "Try again at" / "Try again in"
f="$TMPDIR/sig4a.txt"
printf "Service unavailable. Try again at Apr 16th, 2026 12:04 AM.\n" > "$f"
assert_detect "'Try again at <time>'" "$f" "yes"

f="$TMPDIR/sig4b.txt"
printf "Please try again in 30s.\n" > "$f"
assert_detect "'try again in <duration>'" "$f" "yes"

# Signature 5: "quota exceeded"
f="$TMPDIR/sig5.txt"
printf "quota exceeded for this API key\n" > "$f"
assert_detect "'quota exceeded'" "$f" "yes"

# Signature 6: "401 Unauthorized"
f="$TMPDIR/sig6.txt"
printf "HTTP/1.1 401 Unauthorized\nYour authentication token is invalid or expired.\n" > "$f"
assert_detect "'401 Unauthorized' from agent" "$f" "yes"

# Signature 7: "403 Forbidden"
f="$TMPDIR/sig7.txt"
printf "403 Forbidden — your account has been suspended.\n" > "$f"
assert_detect "'403 Forbidden' from agent" "$f" "yes"

echo ""
echo "=== Case-insensitive matching ==="

f="$TMPDIR/case1.txt"
printf "YOU'VE HIT YOUR USAGE LIMIT\n" > "$f"
assert_detect "All uppercase usage-limit" "$f" "yes"

f="$TMPDIR/case2.txt"
printf "QUOTA Exceeded\n" > "$f"
assert_detect "Mixed-case quota exceeded" "$f" "yes"

f="$TMPDIR/case3.txt"
printf "ERROR: rate LIMIT reached\n" > "$f"
assert_detect "Mixed-case rate limit with error context" "$f" "yes"

echo ""
echo "=== ANSI-wrapped signatures ==="

f="$TMPDIR/ansi1.txt"
printf '\e[1;31mERROR: You'\''ve hit your usage limit\e[0m\n' > "$f"
assert_detect "ANSI-wrapped 'usage limit' (bold red)" "$f" "yes"

f="$TMPDIR/ansi2.txt"
printf '\e[0m\e[33m403 Forbidden\e[0m\n' > "$f"
assert_detect "ANSI-wrapped '403 Forbidden'" "$f" "yes"

f="$TMPDIR/ansi_user_tier.txt"
printf '\e[1;31mYou'\''ve hit your limit · resets 11:30pm (Europe/Berlin)\e[0m\n' > "$f"
assert_detect "ANSI-wrapped Claude user-tier limit reset" "$f" "yes"

echo ""
echo "=== Multi-line realistic fixtures ==="

f="$TMPDIR/realistic.txt"
{
  printf '\e[0m\n'
  printf 'Loading lens prompt...\n'
  printf 'Sending request to agent...\n'
  for i in $(seq 1 40); do
    printf 'some noise line %d\n' "$i"
  done
  printf '\e[1;31mERROR: You'\''ve hit your usage limit. Try again at Apr 16th, 2026 12:04 AM.\e[0m\n'
  printf 'Aborting.\n'
} > "$f"
assert_detect "Realistic multi-line agent output with signature on line ~45" "$f" "yes"

echo ""
echo "=== Output format (PATTERN|SNIPPET) ==="

f="$TMPDIR/format.txt"
printf "ERROR: You've hit your usage limit. Please try again later.\n" > "$f"
assert_output_contains_pipe "Output contains pipe separator between pattern and snippet" "$f"

echo ""
echo "=== Negative fixtures (must NOT match) ==="

# Empty file
f="$TMPDIR/neg_empty.txt"
printf '' > "$f"
assert_detect "Empty file" "$f" "no"

# Plain DONE output
f="$TMPDIR/neg_done.txt"
printf "Analysis complete. No issues found.\nDONE\n" > "$f"
assert_detect "Plain DONE output (no signatures)" "$f" "no"

# Benign agent output with github issue URLs
f="$TMPDIR/neg_issue_urls.txt"
printf "Found vulnerability.\nCreated issue: https://github.com/org/repo/issues/42\nDONE\n" > "$f"
assert_detect "Benign output with gh issue URLs" "$f" "no"

# Agent output that mentions DONE and normal analysis
f="$TMPDIR/neg_analysis.txt"
printf "I analyzed the authentication module and found no issues.\nDONE\n" > "$f"
assert_detect "Regular analysis output" "$f" "no"

f="$TMPDIR/neg_missing_dep.txt"
printf "This project is missing a dependency lockfile.\nDONE\n" > "$f"
assert_detect "Benign finding about missing lockfile" "$f" "no"

# Issue #181: gh issue list rows are de-duplication output, not agent/provider
# rate-limit failures. A later unrelated non-zero agent exit must not let this
# earlier table row trip the detector.
f="$TMPDIR/neg_gh_issue_list_rate_limit_title.txt"
{
  printf "Checking existing issues before filing...\n"
  printf "1344\tOPEN\t[MEDIUM] Device registration endpoint lacks rate limiting despite per-user device quota\tsecurity, feature:security/rate-abuse\t2026-04-29T13:04:42Z\n"
  printf "tool failed: command timed out\n"
} > "$f"
assert_detect "gh issue list row with rate limiting in title" "$f" "no"

f="$TMPDIR/neg_gh_issue_list_spaces.txt"
{
  printf "Checking existing issues before filing...\n"
  printf "  1344  OPEN  [MEDIUM] Device registration endpoint lacks rate limiting despite per-user device quota  security  2026-04-29T13:04:42Z\n"
  printf "transient subprocess failure\n"
} > "$f"
assert_detect "space-delimited gh issue list row with rate limiting in title" "$f" "no"

f="$TMPDIR/neg_plain_finding_rate_limiting.txt"
printf "Finding: device registration endpoint lacks rate limiting despite per-user device quota.\nDONE\n" > "$f"
assert_detect "Plain finding sentence with rate limiting but no error context" "$f" "no"

f="$TMPDIR/neg_plain_usage_limit.txt"
printf "Finding: the project has a configurable usage limit for free-tier accounts.\nDONE\n" > "$f"
assert_detect "Plain finding sentence with usage limit but no error context" "$f" "no"

f="$TMPDIR/neg_bare_hit_your_limit.txt"
printf "Finding: the signup form says you've hit your limit when a plan quota is exhausted.\nDONE\n" > "$f"
assert_detect "Bare you've-hit-your-limit copy without resets marker" "$f" "no"

f="$TMPDIR/neg_gh_issue_list_closed.txt"
{
  printf "Checking closed issues before filing...\n"
  printf "891\tCLOSED\t[LOW] API client retries hide rate limit errors from callers\tbug\t2026-04-20T10:00:00Z\n"
  printf "tool failed: command timed out\n"
} > "$f"
assert_detect "closed gh issue list row with rate limit in title" "$f" "no"

f="$TMPDIR/neg_gh_issue_list_user_tier_title.txt"
{
  printf "Checking existing issues before filing...\n"
  printf "209\tOPEN\t[HIGH] Claude says You've hit your limit · resets 11:30pm (Europe/Berlin)\tbug\t2026-05-13T09:34:55Z\n"
  printf "tool failed: command timed out\n"
} > "$f"
assert_detect "gh issue list row with Claude user-tier limit title" "$f" "no"

echo ""
echo "=== gh 401 leakage (must NOT reach detector — but verify fixture-safely) ==="

# If the orchestrator's own `gh` 401 ever leaks into the output file
# (it should not, per the run_agent redirect), we still want to know.
# This test ensures our detector correctly flags 401 from ANY source,
# because in practice a rate-limited agent emits the same string.
# The orchestrator contract (separate test) ensures gh 401 stays out
# of the output file.
f="$TMPDIR/auth401.txt"
printf "gh: 401 Unauthorized — the provided token is invalid.\n" > "$f"
assert_detect "401 Unauthorized anywhere in output (detector-level)" "$f" "yes"

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
