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

# Integration test for issue #181: a non-zero agent iteration that already
# printed gh issue list output containing "rate limiting" in an issue title
# must not be classified as an upstream agent/provider rate-limit failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"
RUN_ID=""

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  rm -rf "$TMPDIR"
  if [[ -n "${RUN_ID:-}" ]]; then
    rm -rf "$SCRIPT_DIR/logs/$RUN_ID"
  fi
}
trap cleanup EXIT

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (unexpected needle='$needle' found)"
  fi
}

echo "=== Orchestrator gh issue list rate-limit false positive (issue #181) ==="

PROJECT="$TMPDIR/project"
mkdir -p "$PROJECT"
(
  cd "$PROJECT"
  git init -q 2>/dev/null
  git config user.email test@example.com
  git config user.name Test
  printf '# test\n' > README.md
  git add README.md
  git commit -q -m init 2>/dev/null
) || true

FAKE_BIN="$TMPDIR/bin"
STATE_FILE="$TMPDIR/codex-count"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
count=0
if [[ -f "${REPOLENS_TEST_STATE:?}" ]]; then
  count="$(cat "$REPOLENS_TEST_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$REPOLENS_TEST_STATE"

if [[ "$count" -eq 1 ]]; then
  cat <<'MSG'
Checking existing issues before filing...
1344	OPEN	[MEDIUM] Device registration endpoint lacks rate limiting despite per-user device quota	security, feature:security/rate-abuse	2026-04-29T13:04:42Z
tool failed: command timed out
MSG
  exit 2
fi

echo "Analysis complete. No findings."
echo "DONE"
exit 0
SH
chmod +x "$FAKE_BIN/codex"

export PATH="$FAKE_BIN:$PATH"
export REPOLENS_TEST_STATE="$STATE_FILE"

which_codex="$(command -v codex 2>/dev/null || true)"
assert_eq "Fake codex is first on PATH" "$FAKE_BIN/codex" "$which_codex"

OUT_FILE="$TMPDIR/run.log"
set +e
bash "$SCRIPT_DIR/repolens.sh" \
  --project "$PROJECT" \
  --agent codex \
  --domain i18n \
  --mode audit \
  --local \
  --yes \
  >"$OUT_FILE" 2>&1
exit_code=$?
set -e

RUN_ID="$(grep -oE 'RepoLens run [^ ]+ starting' "$OUT_FILE" | head -1 | awk '{print $3}')"
if [[ -z "${RUN_ID:-}" ]]; then
  echo "FAIL: could not parse run_id from repolens.sh output" >&2
  echo "---- run.log ----"
  cat "$OUT_FILE"
  echo "-----------------"
  exit 1
fi

summary_file="$SCRIPT_DIR/logs/$RUN_ID/summary.json"
sentinel_file="$SCRIPT_DIR/logs/$RUN_ID/.rate-limit-abort"
log_contents="$(cat "$OUT_FILE")"

TOTAL=$((TOTAL + 1))
if [[ "$exit_code" -eq 0 ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: Orchestrator exits 0 after unrelated non-zero agent iteration"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Expected exit 0, got $exit_code"
  echo "---- run.log ----"
  cat "$OUT_FILE"
  echo "-----------------"
fi

assert_not_contains "Log does not report terminal rate-limit abort" \
  "rate-limited / quota exceeded" "$log_contents"
assert_not_contains "Log does not report skipped remaining lenses" \
  "Rate-limit abort detected. Skipping remaining lenses." "$log_contents"

TOTAL=$((TOTAL + 1))
if [[ -f "$summary_file" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: summary.json was created at $summary_file"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: summary.json missing (expected $summary_file)"
  echo ""
  echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
  exit "$FAIL"
fi

stopped_reason="$(jq -r '.stopped_reason' "$summary_file")"
assert_eq "summary.stopped_reason remains null" "null" "$stopped_reason"

rate_limited_count="$(jq '[.lenses[] | select(.status == "rate-limited")] | length' "$summary_file")"
assert_eq "No lens has status=rate-limited" "0" "$rate_limited_count"

skipped_count="$(jq '[.lenses[] | select(.status == "skipped")] | length' "$summary_file")"
assert_eq "No lens has status=skipped due to rate-limit abort" "0" "$skipped_count"

TOTAL=$((TOTAL + 1))
if [[ ! -f "$sentinel_file" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: .rate-limit-abort sentinel was not created"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: .rate-limit-abort sentinel was incorrectly created at $sentinel_file"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
exit "$FAIL"
