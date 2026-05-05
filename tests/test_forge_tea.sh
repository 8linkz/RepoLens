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

# Tests for issue #61 - Gitea tea backend for forge_* wrappers.
#
# Behavioral contract:
#   - forge_auth_status with FORGE_PROVIDER=tea checks `tea login list`.
#   - forge_label_create <label> <color> <owner/repo> calls
#     `tea labels create --name <label> --color <color> --repo <project-path>
#      --remote origin`
#     and keeps label creation best-effort by swallowing tea failures.
#   - forge_issue_list_count <owner/repo> <label> calls
#     `tea issues list --repo <project-path> --remote origin --labels <label>
#      --state open --limit 1000 --output json`, parses the JSON length, and
#     preserves the same success/failure contract as the gh branch.
#
# All tea calls are PATH-shadowed with a fake tea stub. No real Gitea CLI,
# network, login, or repository is required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected='$expected' actual='$actual')"
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
    echo "  FAIL: $desc (expected to contain '$needle'; got '${haystack:0:200}')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (unexpectedly contained '$needle'; got '${haystack:0:200}')"
  fi
}

assert_rc_zero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected rc=0, got rc=$actual)"
  fi
}

assert_rc_nonzero() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" -ne 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected non-zero rc, got 0)"
  fi
}

assert_log_empty() {
  local desc="$1" log_file="$2"
  TOTAL=$((TOTAL + 1))
  if [[ ! -s "$log_file" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected no tea invocation, got '$(cat "$log_file")')"
  fi
}

echo ""
echo "=== Test Suite: forge tea backend (issue #61) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
FORGE_TEST_PROJECT="$TMPDIR/audited project"
mkdir -p "$FAKE_BIN"
mkdir -p "$FORGE_TEST_PROJECT"
FORGE_PROJECT_PATH="$FORGE_TEST_PROJECT"
FORGE_REMOTE_NAME="origin"
cat > "$FAKE_BIN/tea" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_TEA_LOG:-/dev/null}"
if [[ -n "${REPOLENS_FAKE_TEA_ARGV_DUMP+x}" ]]; then
  {
    printf '%s\n' "$#"
    for arg in "$@"; do
      printf '<%s>\n' "$arg"
    done
  } > "$REPOLENS_FAKE_TEA_ARGV_DUMP"
fi
if [[ -n "${REPOLENS_FAKE_TEA_STDERR+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_TEA_STDERR" >&2
fi
if [[ -n "${REPOLENS_FAKE_TEA_STDOUT+x}" ]]; then
  printf '%s\n' "$REPOLENS_FAKE_TEA_STDOUT"
fi
exit "${REPOLENS_FAKE_TEA_RC:-0}"
SH
chmod +x "$FAKE_BIN/tea"

run_wrapper() {
  local provider="$1"; shift
  local fn="$1"; shift
  (
    export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
    export FORGE_PROVIDER="$provider"
    [[ -n "${FORGE_PROJECT_PATH+x}" ]] && export FORGE_PROJECT_PATH
    [[ -n "${FORGE_REMOTE_NAME+x}" ]] && export FORGE_REMOTE_NAME
    [[ -n "${FORGE_TEA_LOGIN+x}" ]] && export FORGE_TEA_LOGIN
    [[ -n "${REPOLENS_FAKE_TEA_RC+x}" ]] && export REPOLENS_FAKE_TEA_RC
    [[ -n "${REPOLENS_FAKE_TEA_LOG+x}" ]] && export REPOLENS_FAKE_TEA_LOG
    [[ -n "${REPOLENS_FAKE_TEA_ARGV_DUMP+x}" ]] && export REPOLENS_FAKE_TEA_ARGV_DUMP
    [[ -n "${REPOLENS_FAKE_TEA_STDOUT+x}" ]] && export REPOLENS_FAKE_TEA_STDOUT
    [[ -n "${REPOLENS_FAKE_TEA_STDERR+x}" ]] && export REPOLENS_FAKE_TEA_STDERR
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/forge.sh"
    "$fn" "$@"
  )
}

reset_fake_tea() {
  unset REPOLENS_FAKE_TEA_RC REPOLENS_FAKE_TEA_LOG
  unset REPOLENS_FAKE_TEA_ARGV_DUMP
  unset REPOLENS_FAKE_TEA_STDOUT REPOLENS_FAKE_TEA_STDERR
}

# ---------------------------------------------------------------------------
# Group 1: forge_auth_status
# ---------------------------------------------------------------------------
echo "--- Group 1: forge_auth_status ---"
echo ""

echo "Test 1: tea auth success calls 'tea login list' and stays silent"
reset_fake_tea
tea_log="$TMPDIR/t1-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_LOG="$tea_log"
err_file="$TMPDIR/t1.err"
out="$(run_wrapper tea forge_auth_status 2>"$err_file")"
rc=$?
assert_rc_zero "forge_auth_status tea returns 0 when tea login list succeeds" "$rc"
assert_eq "forge_auth_status tea prints nothing on stdout" "" "$out"
assert_eq "forge_auth_status tea prints nothing on stderr" "" "$(cat "$err_file")"
assert_eq "tea auth argv uses login list" "login list" "$(cat "$tea_log")"

echo ""
echo "Test 2: tea auth failure dies with the Gitea login hint"
reset_fake_tea
tea_log="$TMPDIR/t2-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_RC=4
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_auth_status 2>&1)"
rc=$?
assert_rc_nonzero "forge_auth_status tea returns non-zero when tea login list fails" "$rc"
assert_contains "die message mentions tea authentication" "tea is not authenticated" "$out"
assert_contains "die message tells the user how to add a tea login" "tea login add" "$out"
assert_eq "tea auth failure still uses login list" "login list" "$(cat "$tea_log")"

# ---------------------------------------------------------------------------
# Group 2: forge_label_create
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: forge_label_create ---"
echo ""

echo "Test 3: tea label create uses --name, --color, --repo project path, and --remote origin"
reset_fake_tea
tea_log="$TMPDIR/t3-tea.log"
argv_dump="$TMPDIR/t3-argv.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_ARGV_DUMP="$argv_dump"
out="$(run_wrapper tea forge_label_create audit:demo abcdef owner/repo 2>&1)"
rc=$?
logged="$(cat "$tea_log")"
argv_content="$(cat "$argv_dump")"
assert_rc_zero "forge_label_create tea succeeds when tea labels create succeeds" "$rc"
assert_eq "forge_label_create tea is silent on success" "" "$out"
assert_eq "tea label argv matches the supported CLI surface" \
  "labels create --name audit:demo --color abcdef --repo $FORGE_TEST_PROJECT --remote origin" "$logged"
assert_eq "tea label argv keeps the spaced project path as one argument" "10" "$(sed -n '1p' "$argv_dump")"
assert_contains "tea label argv includes one full project-path argument" "<$FORGE_TEST_PROJECT>" "$argv_content"
assert_not_contains "tea label argv does not use the rejected --label flag" "--label" "$logged"
assert_not_contains "tea label argv does not rely on owner/repo slug as repo selector" "--repo owner/repo" "$logged"

echo ""
echo "Test 4: tea label create failures remain best-effort"
reset_fake_tea
tea_log="$TMPDIR/t4-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_RC=9
REPOLENS_FAKE_TEA_STDERR='label already exists'
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_label_create audit:demo abcdef owner/repo 2>&1)"
rc=$?
assert_rc_zero "forge_label_create tea swallows non-zero tea exit" "$rc"
assert_eq "forge_label_create tea suppresses failed label stderr" "" "$out"
assert_eq "best-effort label failure still calls tea labels create" \
  "labels create --name audit:demo --color abcdef --repo $FORGE_TEST_PROJECT --remote origin" "$(cat "$tea_log")"

# ---------------------------------------------------------------------------
# Group 3: forge_issue_list_count
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 3: forge_issue_list_count ---"
echo ""

echo "Test 5: tea issues list returning [] prints 0"
reset_fake_tea
tea_log="$TMPDIR/t5-tea.log"
argv_dump="$TMPDIR/t5-argv.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='[]'
REPOLENS_FAKE_TEA_LOG="$tea_log"
REPOLENS_FAKE_TEA_ARGV_DUMP="$argv_dump"
err_file="$TMPDIR/t5.err"
out="$(run_wrapper tea forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
logged="$(cat "$tea_log")"
argv_content="$(cat "$argv_dump")"
assert_rc_zero "empty tea issue list is a successful count" "$rc"
assert_eq "stdout is 0 for legitimately zero matching open Gitea issues" "0" "$out"
assert_eq "stderr is empty on successful tea count" "" "$(cat "$err_file")"
assert_eq "tea issue-list argv matches the accepted flags and order" \
  "issues list --repo $FORGE_TEST_PROJECT --remote origin --labels audit:demo --state open --limit 1000 --output json" "$logged"
assert_eq "tea issue-list argv keeps the spaced project path as one argument" "14" "$(sed -n '1p' "$argv_dump")"
assert_contains "tea issue-list argv includes one full project-path argument" "<$FORGE_TEST_PROJECT>" "$argv_content"
assert_not_contains "tea issue-list argv does not rely on owner/repo slug as repo selector" "--repo owner/repo" "$logged"

echo ""
echo "Test 6: tea issues list returning two objects prints 2"
reset_fake_tea
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='[{"number":1},{"number":2}]'
out="$(run_wrapper tea forge_issue_list_count owner/repo audit:demo 2>/dev/null)"
rc=$?
assert_rc_zero "two tea issues are counted successfully" "$rc"
assert_eq "stdout is 2 for two matching open Gitea issues" "2" "$out"

echo ""
echo "Test 7: tea issues list failure returns non-zero, empty stdout, and warning"
reset_fake_tea
REPOLENS_FAKE_TEA_RC=7
REPOLENS_FAKE_TEA_STDERR='Gitea API unavailable'
err_file="$TMPDIR/t7.err"
out="$(run_wrapper tea forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
stderr_content="$(cat "$err_file")"
assert_rc_nonzero "tea issue-list failure is observable to callers" "$rc"
assert_eq "stdout is empty when tea issues list fails" "" "$out"
assert_contains "warning mentions tea failed" "tea failed" "$stderr_content"
assert_contains "warning includes the tea exit code" "rc=7" "$stderr_content"
assert_contains "warning includes the target repo" "repo=owner/repo" "$stderr_content"
assert_contains "warning includes the target label" "label=audit:demo" "$stderr_content"
assert_contains "warning includes the first tea stderr line" "Gitea API unavailable" "$stderr_content"

echo ""
echo "Test 8: tea issues list non-JSON output returns non-zero with empty stdout"
reset_fake_tea
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='not json'
err_file="$TMPDIR/t8.err"
out="$(run_wrapper tea forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
assert_rc_nonzero "invalid tea JSON is observable to callers" "$rc"
assert_eq "stdout is empty on tea JSON parse failure" "" "$out"
assert_contains "warning mentions jq parse failure for tea" "jq failed to parse tea output" "$(cat "$err_file")"

echo ""
echo "Test 9: non-integer jq output returns non-zero with empty stdout"
reset_fake_tea
cat > "$FAKE_BIN/jq" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' not-a-number
exit 0
SH
chmod +x "$FAKE_BIN/jq"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='[{"number":1}]'
err_file="$TMPDIR/t9.err"
out="$(run_wrapper tea forge_issue_list_count owner/repo audit:demo 2>"$err_file")"
rc=$?
rm -f "$FAKE_BIN/jq"
assert_rc_nonzero "non-integer jq output is observable to callers" "$rc"
assert_eq "stdout is empty on unexpected jq output" "" "$out"
assert_contains "warning mentions unexpected non-integer" "unexpected non-integer" "$(cat "$err_file")"

echo ""
echo "Test 10: missing issue label dies before invoking tea"
reset_fake_tea
tea_log="$TMPDIR/t10-tea.log"
: > "$tea_log"
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_issue_list_count owner/repo "" 2>&1)"
rc=$?
assert_rc_nonzero "missing issue label exits non-zero" "$rc"
assert_contains "missing issue label reports missing argument" "missing argument" "$out"
assert_log_empty "missing issue label does not call tea" "$tea_log"

echo ""
echo "Test 11: tea label create requires explicit target binding"
reset_fake_tea
tea_log="$TMPDIR/t11-tea.log"
: > "$tea_log"
saved_forge_project_path="$FORGE_PROJECT_PATH"
unset FORGE_PROJECT_PATH FORGE_TEA_LOGIN
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_label_create audit:demo abcdef owner/repo 2>&1)"
rc=$?
FORGE_PROJECT_PATH="$saved_forge_project_path"
assert_rc_nonzero "missing tea label target binding exits non-zero" "$rc"
assert_contains "missing tea label target binding explains target binding" "target binding" "$out"
assert_log_empty "missing tea label target binding does not call tea" "$tea_log"

echo ""
echo "Test 12: tea issue count requires explicit target binding"
reset_fake_tea
tea_log="$TMPDIR/t12-tea.log"
: > "$tea_log"
saved_forge_project_path="$FORGE_PROJECT_PATH"
unset FORGE_PROJECT_PATH FORGE_TEA_LOGIN
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_issue_list_count owner/repo audit:demo 2>&1)"
rc=$?
FORGE_PROJECT_PATH="$saved_forge_project_path"
assert_rc_nonzero "missing tea issue-count target binding exits non-zero" "$rc"
assert_contains "missing tea issue-count target binding explains target binding" "target binding" "$out"
assert_log_empty "missing tea issue-count target binding does not call tea" "$tea_log"

echo ""
echo "Test 13: tea label create can use FORGE_TEA_LOGIN when project path is unavailable"
reset_fake_tea
tea_log="$TMPDIR/t13-tea.log"
: > "$tea_log"
saved_forge_project_path="$FORGE_PROJECT_PATH"
unset FORGE_PROJECT_PATH
FORGE_TEA_LOGIN="work-login"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_label_create audit:demo abcdef owner/repo 2>&1)"
rc=$?
FORGE_PROJECT_PATH="$saved_forge_project_path"
unset FORGE_TEA_LOGIN
logged="$(cat "$tea_log")"
assert_rc_zero "FORGE_TEA_LOGIN label fallback exits zero" "$rc"
assert_eq "FORGE_TEA_LOGIN label fallback is silent on success" "" "$out"
assert_eq "FORGE_TEA_LOGIN label fallback uses owner/repo plus login" \
  "labels create --name audit:demo --color abcdef --repo owner/repo --login work-login" "$logged"
assert_not_contains "FORGE_TEA_LOGIN label fallback does not pass a remote selector" "--remote" "$logged"

echo ""
echo "Test 14: tea issue count can use FORGE_TEA_LOGIN when project path is unavailable"
reset_fake_tea
tea_log="$TMPDIR/t14-tea.log"
: > "$tea_log"
saved_forge_project_path="$FORGE_PROJECT_PATH"
unset FORGE_PROJECT_PATH
FORGE_TEA_LOGIN="work-login"
REPOLENS_FAKE_TEA_RC=0
REPOLENS_FAKE_TEA_STDOUT='[{"number":1},{"number":2}]'
REPOLENS_FAKE_TEA_LOG="$tea_log"
out="$(run_wrapper tea forge_issue_list_count owner/repo audit:demo 2>/dev/null)"
rc=$?
FORGE_PROJECT_PATH="$saved_forge_project_path"
unset FORGE_TEA_LOGIN
logged="$(cat "$tea_log")"
assert_rc_zero "FORGE_TEA_LOGIN issue-count fallback exits zero" "$rc"
assert_eq "FORGE_TEA_LOGIN issue-count fallback prints jq length" "2" "$out"
assert_eq "FORGE_TEA_LOGIN issue-count fallback uses owner/repo plus login" \
  "issues list --repo owner/repo --login work-login --labels audit:demo --state open --limit 1000 --output json" "$logged"
assert_not_contains "FORGE_TEA_LOGIN issue-count fallback does not pass a remote selector" "--remote" "$logged"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
