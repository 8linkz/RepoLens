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

# Tests for issue #173 — Cost guardrails:
#   - Round-aware cost estimator (lens x depth x rounds)
#   - Per-round breakdown lines surfaced in dry-run
#   - REPOLENS_MAX_ROUNDS hard ceiling (default 5, >= semantics)
#   - --rounds >= 4 explicit-ack gate (--max-cost AND --yes, or --i-know-this-is-expensive)
#   - --i-know-this-is-expensive flag (bypasses ack gate, NOT the ceiling)
#
# All cases use --dry-run plus a fake-codex agent. No real models are invoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP_PARENT="$SCRIPT_DIR/logs/test-cost-guardrails"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"
CREATED_RUN_IDS=()
BUG_FILE="$TMPDIR/bug-report.md"
printf 'Cost guardrail fixture bug report — placeholder text.\n' > "$BUG_FILE"

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
FAKE_BIN="$TMPDIR/bin"
LAST_OUTPUT_FILE=""
LAST_RC=0

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

assert_nonzero_rc() {
  local desc="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" != "0" ]]; then
    pass_with "$desc"
  else
    fail_with "$desc" "Expected non-zero exit, got 0"
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

make_fake_codex() {
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'DONE\n'
EOF
  chmod +x "$FAKE_BIN/codex"
}

make_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
  # Enough source bytes so the cost estimator emits a non-zero MIN_COST
  for i in $(seq 1 20); do
    printf 'line %d of seed source — keep the repo above the 1k-token threshold\n' "$i" \
      >> "$project/src.txt"
  done
  printf '# cost guardrails fixture\n' > "$project/README.md"
}

last_output() {
  cat "$LAST_OUTPUT_FILE"
}

register_created_run_id() {
  local run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$LAST_OUTPUT_FILE" 2>/dev/null | head -1 | awk '{print $3}')"
  if [[ -n "$run_id" ]]; then
    CREATED_RUN_IDS+=("$run_id")
  fi
}

# Run repolens with an isolated env. First arg = case name; remaining args
# are forwarded to repolens.sh. REPOLENS_ROUNDS / REPOLENS_MAX_ROUNDS are
# stripped from the calling shell so each case starts from a clean slate
# unless the test explicitly re-injects one (see run_repolens_with_env).
run_repolens() {
  local name="$1"
  shift

  local project="$TMPDIR/proj-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/out-$name.txt"

  env -u REPOLENS_ROUNDS -u REPOLENS_MAX_ROUNDS -u DONE_STREAK_REQUIRED \
    PATH="$FAKE_BIN:$PATH" \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$project" \
      --agent codex \
      --mode bugreport \
      --bug-report "$BUG_FILE" \
      --local \
      --output "$TMPDIR/issues-$name" \
      "$@" </dev/null >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
  register_created_run_id
}

# Same as run_repolens but lets the caller pre-set env vars via NAME=VALUE
# tokens BEFORE a `--` sentinel. Tokens after `--` go to repolens.sh.
run_repolens_with_env() {
  local name="$1"
  shift

  local -a env_extras=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_extras+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift

  local project="$TMPDIR/proj-$name"
  make_project "$project"

  LAST_OUTPUT_FILE="$TMPDIR/out-$name.txt"

  env -u REPOLENS_ROUNDS -u REPOLENS_MAX_ROUNDS -u DONE_STREAK_REQUIRED \
    PATH="$FAKE_BIN:$PATH" \
    "${env_extras[@]}" \
    bash "$SCRIPT_DIR/repolens.sh" \
      --project "$project" \
      --agent codex \
      --mode bugreport \
      --bug-report "$BUG_FILE" \
      --local \
      --output "$TMPDIR/issues-$name" \
      "$@" </dev/null >"$LAST_OUTPUT_FILE" 2>&1
  LAST_RC=$?
  register_created_run_id
}

# Pull a numeric MIN_COST from cost-block output. The estimator's awk block
# emits "MIN_COST=<dollars>" (research §2.2 / §5.4). Whether the implementer
# leaves that exact line in dry-run output or formats it differently, the
# scaling test uses a more lenient extraction that works for either:
#   - "MIN_COST=12.34" (raw passthrough)
#   - "Estimated cost: ~$12.34 (...)" (formatted single-line message)
extract_min_cost() {
  local file="$1"
  local val
  val="$(grep -oE 'MIN_COST=[0-9]+\.[0-9]+' "$file" | head -1 | cut -d= -f2)"
  if [[ -z "$val" ]]; then
    val="$(grep -oE 'Estimated cost:[[:space:]]*~?\$[0-9]+\.[0-9]+' "$file" \
      | head -1 | grep -oE '[0-9]+\.[0-9]+')"
  fi
  printf '%s' "$val"
}

echo ""
echo "=== Test Suite: cost guardrails (issue #173) ==="
echo ""

make_fake_codex

echo "Test 1: dry-run with --rounds 1 surfaces a cost estimate"
run_repolens "rounds1-cost-shown" --rounds 1 --yes --dry-run
assert_eq "rounds=1 dry-run exits 0" "0" "$LAST_RC"
assert_contains "rounds=1 dry-run prints an Estimated cost line" \
                "Estimated cost" "$(last_output)"

echo ""
echo "Test 2: dry-run with --rounds 3 emits per-round breakdown lines"
run_repolens "rounds3-breakdown" --rounds 3 --yes --dry-run
assert_eq "rounds=3 dry-run exits 0" "0" "$LAST_RC"
out_r3="$(last_output)"
assert_contains "rounds=3 dry-run includes round-1 line" "round-1" "$out_r3"
assert_contains "rounds=3 dry-run includes round-2 line" "round-2" "$out_r3"
assert_contains "rounds=3 dry-run includes round-3 line" "round-3" "$out_r3"
assert_contains "rounds=3 dry-run names the rounds factor in the cost line" \
                "rounds=3" "$out_r3"
assert_contains "rounds=3 dry-run names the lens_count factor" \
                "lens_count=" "$out_r3"
assert_contains "rounds=3 dry-run names the depth factor" \
                "depth=" "$out_r3"

echo ""
echo "Test 3: rounds=1 dry-run does NOT print per-round breakdown noise"
run_repolens "rounds1-no-breakdown" --rounds 1 --yes --dry-run
assert_eq "rounds=1 dry-run exits 0" "0" "$LAST_RC"
# Per-round lines only emit when rounds > 1 (research §5.4 & §10).
assert_not_contains "rounds=1 omits round-2 noise" "round-2" "$(last_output)"

echo ""
echo "Test 4: cost estimate scales linearly with --rounds"
# Use the fixtures from the prior runs to compare cost(rounds=1) vs cost(rounds=3).
cost_r1="$(extract_min_cost "$TMPDIR/out-rounds1-cost-shown.txt")"
cost_r3="$(extract_min_cost "$TMPDIR/out-rounds3-breakdown.txt")"
TOTAL=$((TOTAL + 1))
if [[ -z "$cost_r1" || -z "$cost_r3" ]]; then
  fail_with "extracted MIN_COST for rounds=1 and rounds=3" \
            "rounds=1 cost='$cost_r1' rounds=3 cost='$cost_r3' (estimator must surface a parseable dollar value in dry-run)"
else
  # Allow ±10% slack for rounding; rounds=3 must be ~3x rounds=1.
  ratio_ok="$(awk -v a="$cost_r3" -v b="$cost_r1" \
    'BEGIN { if (b == 0) { print 0; exit } r = a / b; print (r >= 2.7 && r <= 3.3) ? 1 : 0 }')"
  if [[ "$ratio_ok" == "1" ]]; then
    pass_with "cost(rounds=3) ≈ 3 × cost(rounds=1) (got $cost_r3 vs $cost_r1)"
  else
    fail_with "cost(rounds=3) ≈ 3 × cost(rounds=1)" \
              "rounds=1=$cost_r1 rounds=3=$cost_r3 — ratio outside [2.7, 3.3]"
  fi
fi

echo ""
echo "Test 5: --rounds 4 with no ack and no --max-cost+--yes aborts with the literal message"
run_repolens "rounds4-no-ack" --rounds 4 --dry-run
assert_nonzero_rc "rounds=4 without ack exits non-zero" "$LAST_RC"
assert_contains "rounds=4 abort uses the exact message from issue #173 §4" \
                "rounds >= 4 requires --max-cost <USD> AND --yes (or pass --i-know-this-is-expensive)" \
                "$(last_output)"

echo ""
echo "Test 6: --rounds 4 with only --yes (no --max-cost) still aborts"
run_repolens "rounds4-yes-only" --rounds 4 --yes --dry-run
assert_nonzero_rc "rounds=4 with only --yes exits non-zero" "$LAST_RC"
assert_contains "rounds=4 with only --yes triggers the explicit-ack abort" \
                "rounds >= 4 requires --max-cost" "$(last_output)"

echo ""
echo "Test 7: --rounds 4 with only --max-cost (no --yes) still aborts"
run_repolens "rounds4-maxcost-only" --rounds 4 --max-cost 100 --dry-run
assert_nonzero_rc "rounds=4 with only --max-cost exits non-zero" "$LAST_RC"
assert_contains "rounds=4 with only --max-cost triggers the explicit-ack abort" \
                "rounds >= 4 requires --max-cost" "$(last_output)"

echo ""
echo "Test 8: --rounds 4 with --max-cost AND --yes proceeds"
run_repolens "rounds4-maxcost-yes" --rounds 4 --max-cost 100 --yes --dry-run
assert_eq "rounds=4 with --max-cost + --yes exits 0" "0" "$LAST_RC"
assert_not_contains "rounds=4 with --max-cost + --yes does NOT print the abort message" \
                    "rounds >= 4 requires --max-cost" "$(last_output)"

echo ""
echo "Test 9: --rounds 4 with --i-know-this-is-expensive proceeds"
run_repolens "rounds4-ack" --rounds 4 --i-know-this-is-expensive --dry-run
assert_eq "rounds=4 with --i-know-this-is-expensive exits 0" "0" "$LAST_RC"
assert_not_contains "rounds=4 with ack does NOT print the abort message" \
                    "rounds >= 4 requires --max-cost" "$(last_output)"

echo ""
echo "Test 10: REPOLENS_MAX_ROUNDS=3 + --rounds 5 + ack still aborts (ack does NOT bypass ceiling)"
run_repolens_with_env "ceiling-3-rounds5-ack" \
  REPOLENS_MAX_ROUNDS=3 -- \
  --rounds 5 --i-know-this-is-expensive --dry-run
assert_nonzero_rc "ceiling=3 + rounds=5 + ack exits non-zero" "$LAST_RC"
assert_contains "ceiling abort names REPOLENS_MAX_ROUNDS" \
                "REPOLENS_MAX_ROUNDS" "$(last_output)"

echo ""
echo "Test 11: default ceiling 5 + --rounds 5 aborts on >= semantics"
# Per the issue test plan: 'REPOLENS_MAX_ROUNDS unset, --rounds 5 → aborts on
# the default ceiling of 5 (i.e., >= not >)'.
run_repolens "default-ceiling-rounds5-ack" \
  --rounds 5 --i-know-this-is-expensive --dry-run
assert_nonzero_rc "default ceiling 5 + rounds=5 exits non-zero (>= semantics)" "$LAST_RC"
assert_contains "default ceiling abort names REPOLENS_MAX_ROUNDS" \
                "REPOLENS_MAX_ROUNDS" "$(last_output)"

echo ""
echo "Test 12: REPOLENS_MAX_ROUNDS rejects non-positive-integer values"
run_repolens_with_env "invalid-ceiling-abc" \
  REPOLENS_MAX_ROUNDS=abc -- \
  --rounds 1 --yes --dry-run
assert_nonzero_rc "REPOLENS_MAX_ROUNDS=abc exits non-zero" "$LAST_RC"
assert_contains "REPOLENS_MAX_ROUNDS=abc names the variable in the validation error" \
                "REPOLENS_MAX_ROUNDS" "$(last_output)"
assert_contains "REPOLENS_MAX_ROUNDS=abc names the positive-integer requirement" \
                "positive integer" "$(last_output)"

echo ""
echo "Test 12b: REPOLENS_MAX_ROUNDS=0 is rejected (numeric but not positive)"
# Distinct from Test 12 ('abc' = non-numeric): the regex ^[1-9][0-9]*$ also
# rejects 0 and other non-positive integers. Without this guard, a regex
# weakened to ^[0-9]+$ would accept 0, and (( ROUNDS >= 0 )) would abort
# every run unconditionally.
run_repolens_with_env "invalid-ceiling-zero" \
  REPOLENS_MAX_ROUNDS=0 -- \
  --rounds 1 --yes --dry-run
assert_nonzero_rc "REPOLENS_MAX_ROUNDS=0 exits non-zero" "$LAST_RC"
assert_contains "REPOLENS_MAX_ROUNDS=0 names the variable in the validation error" \
                "REPOLENS_MAX_ROUNDS" "$(last_output)"
assert_contains "REPOLENS_MAX_ROUNDS=0 names the positive-integer requirement" \
                "positive integer" "$(last_output)"

echo ""
echo "Test 13: --help documents --i-know-this-is-expensive and REPOLENS_MAX_ROUNDS"
help_out="$(env -u REPOLENS_ROUNDS -u REPOLENS_MAX_ROUNDS \
  bash "$SCRIPT_DIR/repolens.sh" --help 2>&1)"
assert_contains "--help lists --i-know-this-is-expensive" \
                "--i-know-this-is-expensive" "$help_out"
assert_contains "--help lists REPOLENS_MAX_ROUNDS" \
                "REPOLENS_MAX_ROUNDS" "$help_out"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
