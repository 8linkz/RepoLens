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

# Issue #236: multi-round audit/feature/bugfix/custom is silent no-op.
# RFC #235 closure (Option B): non-bugreport modes do not support multi-round.
# This test locks in the contract that --rounds > 1 is rejected for every mode
# except bugreport, and accepted for bugreport.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP_PARENT="$SCRIPT_DIR/logs/test-rounds-non-bugreport-rejected"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()

cleanup() {
  local run_id
  rm -rf "$TMPDIR"
  for run_id in "${CREATED_RUN_IDS[@]:-}"; do
    [[ -n "$run_id" ]] && rm -rf "$SCRIPT_DIR/logs/$run_id"
  done
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

PASS=0
FAIL=0
TOTAL=0

pass_with() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Did not expect output to contain: $needle"
  fi
}

register_created_run_id() {
  local output_file="$1"
  local run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$output_file" 2>/dev/null | head -1 | awk '{print $3}')"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

PROJECT_DIR="$TMPDIR/project"
FAKE_BIN="$TMPDIR/bin"
BUG_FILE="$TMPDIR/bug-report.md"
mkdir -p "$PROJECT_DIR" "$FAKE_BIN"
git -C "$PROJECT_DIR" init -q
printf '# RepoLens issue 236 fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" \
  -c user.name='RepoLens Test' \
  -c user.email='repolens@example.invalid' \
  add README.md
git -C "$PROJECT_DIR" \
  -c user.name='RepoLens Test' \
  -c user.email='repolens@example.invalid' \
  commit -q -m 'fixture'

printf 'Issue 236 negative test placeholder bug report.\n' > "$BUG_FILE"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf 'DONE\n'
EOF
chmod +x "$FAKE_BIN/codex"

echo ""
echo "=== Test Suite: --rounds rejected for non-bugreport modes (issue #236) ==="
echo ""

# ------------------------------------------------------------------------
# Test 1: --rounds 2 is rejected for every non-bugreport mode.
# ------------------------------------------------------------------------
echo "Test 1: --rounds 2 is rejected for audit/feature/bugfix/custom"
for mode in audit feature bugfix custom; do
  out_file="$TMPDIR/reject-$mode.txt"
  args=(--project "$PROJECT_DIR" --agent codex --local --mode "$mode" --rounds 2
        --yes --dry-run --output "$TMPDIR/issues-$mode")
  if [[ "$mode" == "custom" ]]; then
    args+=(--change "Test change")
  fi

  env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 PATH="$FAKE_BIN:$PATH" \
    bash "$SCRIPT_DIR/repolens.sh" "${args[@]}" >"$out_file" 2>&1
  rc=$?
  register_created_run_id "$out_file"

  assert_eq "--rounds 2 --mode $mode exits non-zero" "1" "$rc"
  assert_contains "--rounds 2 --mode $mode error names the per-mode cap" \
                  "--rounds 2 exceeds cap for mode '$mode' (max: 1)" "$(cat "$out_file")"
done

# ------------------------------------------------------------------------
# Test 2: --rounds 2 is also rejected for the already-locked exclusive modes
# (defense in depth — ensures the existing contract did not regress).
# ------------------------------------------------------------------------
echo ""
echo "Test 2: --rounds 2 stays rejected for deploy/opensource/content/discover"
for mode in deploy opensource content discover; do
  out_file="$TMPDIR/reject-$mode.txt"
  env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 PATH="$FAKE_BIN:$PATH" \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$PROJECT_DIR" \
      --agent codex \
      --local \
      --mode "$mode" \
      --rounds 2 \
      --yes \
      --dry-run \
      --output "$TMPDIR/issues-$mode" \
      >"$out_file" 2>&1
  rc=$?
  register_created_run_id "$out_file"

  assert_eq "--rounds 2 --mode $mode exits non-zero" "1" "$rc"
  assert_contains "--rounds 2 --mode $mode error names the per-mode cap" \
                  "--rounds 2 exceeds cap for mode '$mode' (max: 1)" "$(cat "$out_file")"
done

# ------------------------------------------------------------------------
# Test 3: bugreport STILL accepts multi-round (sanity / inverse contract).
# ------------------------------------------------------------------------
echo ""
echo "Test 3: --rounds 2 --mode bugreport is accepted"
out_file="$TMPDIR/accept-bugreport.txt"
env -u REPOLENS_ROUNDS -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 PATH="$FAKE_BIN:$PATH" \
  bash "$SCRIPT_DIR/repolens.sh" \
    --project "$PROJECT_DIR" \
    --agent codex \
    --local \
    --mode bugreport \
    --bug-report "$BUG_FILE" \
    --rounds 2 \
    --yes \
    --dry-run \
    --output "$TMPDIR/issues-bugreport" \
    >"$out_file" 2>&1
rc=$?
register_created_run_id "$out_file"

assert_eq "--rounds 2 --mode bugreport exits successfully" "0" "$rc"
assert_not_contains "--rounds 2 --mode bugreport does not surface a cap error" \
                    "exceeds cap" "$(cat "$out_file")"
assert_contains "--rounds 2 --mode bugreport displays --rounds 2" \
                "Rounds:      2" "$(cat "$out_file")"

# ------------------------------------------------------------------------
# Test 4: REPOLENS_ROUNDS env path enforces the same per-mode caps.
# ------------------------------------------------------------------------
echo ""
echo "Test 4: REPOLENS_ROUNDS=2 is rejected for non-bugreport modes"
for mode in audit feature bugfix custom; do
  out_file="$TMPDIR/env-reject-$mode.txt"
  args=(--project "$PROJECT_DIR" --agent codex --local --mode "$mode"
        --yes --dry-run --output "$TMPDIR/issues-env-$mode")
  if [[ "$mode" == "custom" ]]; then
    args+=(--change "Test change")
  fi

  env -u DONE_STREAK_REQUIRED REPOLENS_MAX_ROUNDS=99 REPOLENS_ROUNDS=2 PATH="$FAKE_BIN:$PATH" \
    bash "$SCRIPT_DIR/repolens.sh" "${args[@]}" >"$out_file" 2>&1
  rc=$?
  register_created_run_id "$out_file"

  assert_eq "REPOLENS_ROUNDS=2 --mode $mode exits non-zero" "1" "$rc"
  assert_contains "REPOLENS_ROUNDS=2 --mode $mode error names the per-mode cap" \
                  "REPOLENS_ROUNDS 2 exceeds cap for mode '$mode' (max: 1)" "$(cat "$out_file")"
done

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
