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

# Tests for issue #243 — fj label color contract: pass `#RRGGBB`, not bare hex.
#
# Behavioral contract:
#   - forge_label_create with FORGE_PROVIDER=fj prefixes the color with `#`
#     when the caller supplies bare hex (e.g. `abcdef` -> `#abcdef`). gh and
#     tea branches must remain unchanged (they accept bare hex either way).
#   - forge_label_create is idempotent: a caller-supplied `#abcdef` must
#     pass through as `#abcdef` (no `##abcdef` doubling).
#   - forge_prompt_label_create renders the same `#RRGGBB` shape in the
#     embedded shell command emitted to agent prompts, with the same
#     idempotency property.
#
# All fj calls are PATH-shadowed with a fake fj stub. No real Forgejo CLI,
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
    echo "  FAIL: $desc (did not expect '$needle' in: '${haystack:0:200}')"
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

echo ""
echo "=== Test Suite: forge fj label color contract (issue #243) ==="
echo ""

[[ -f "$SCRIPT_DIR/lib/forge.sh" ]] || { echo "FAIL: lib/forge.sh missing"; exit 1; }
[[ -f "$SCRIPT_DIR/lib/core.sh" ]]  || { echo "FAIL: lib/core.sh missing"; exit 1; }

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/fj" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REPOLENS_FAKE_FJ_LOG:-/dev/null}"
exit "${REPOLENS_FAKE_FJ_RC:-0}"
SH
chmod +x "$FAKE_BIN/fj"

run_wrapper() {
  local fn="$1"; shift
  (
    export PATH="$FAKE_BIN:/usr/bin:/bin:$PATH"
    export FORGE_PROVIDER=fj
    [[ -n "${FORGE_HOST+x}" ]] && export FORGE_HOST
    [[ -n "${REPOLENS_FAKE_FJ_RC+x}" ]] && export REPOLENS_FAKE_FJ_RC
    [[ -n "${REPOLENS_FAKE_FJ_LOG+x}" ]] && export REPOLENS_FAKE_FJ_LOG
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/core.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/forge.sh"
    "$fn" "$@"
  )
}

reset_fake_fj() {
  unset REPOLENS_FAKE_FJ_RC REPOLENS_FAKE_FJ_LOG
}

# ---------------------------------------------------------------------------
# Group 1: forge_label_create — fj color contract
# ---------------------------------------------------------------------------
echo "--- Group 1: forge_label_create fj color contract ---"
echo ""

echo "Test 1: bare-hex color is normalized to #RRGGBB for fj argv"
reset_fake_fj
fj_log="$TMPDIR/t1-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper forge_label_create audit:demo abcdef owner/repo 2>&1)"
rc=$?
logged="$(cat "$fj_log")"
assert_rc_zero "forge_label_create fj returns 0 on success" "$rc"
assert_eq "fj label argv prefixes bare hex with #" \
  "-H codeberg.org repo labels owner/repo create audit:demo #abcdef" "$logged"

echo ""
echo "Test 2: caller-supplied #abcdef is preserved (idempotent, no ##abcdef)"
reset_fake_fj
fj_log="$TMPDIR/t2-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper forge_label_create audit:demo '#abcdef' owner/repo 2>&1)"
rc=$?
logged="$(cat "$fj_log")"
assert_rc_zero "forge_label_create fj accepts #-prefixed color" "$rc"
assert_eq "fj label argv does not double the # prefix" \
  "-H codeberg.org repo labels owner/repo create audit:demo #abcdef" "$logged"
assert_not_contains "fj label argv has no ## sequence" "##" "$logged"

echo ""
echo "Test 3: real config color (d73a4a from label-colors.json) becomes #d73a4a"
reset_fake_fj
fj_log="$TMPDIR/t3-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=0
REPOLENS_FAKE_FJ_LOG="$fj_log"
out="$(run_wrapper forge_label_create audit:security d73a4a owner/repo 2>&1)"
rc=$?
logged="$(cat "$fj_log")"
assert_rc_zero "forge_label_create fj handles real config color" "$rc"
assert_eq "fj label argv prefixes d73a4a with #" \
  "-H codeberg.org repo labels owner/repo create audit:security #d73a4a" "$logged"

echo ""
echo "Test 4: failure path still uses #-prefixed color (best-effort preserved)"
reset_fake_fj
fj_log="$TMPDIR/t4-fj.log"
: > "$fj_log"
FORGE_HOST=codeberg.org
REPOLENS_FAKE_FJ_RC=9
REPOLENS_FAKE_FJ_LOG="$fj_log"
# shellcheck disable=SC2034  # captured to suppress wrapper stdout/stderr in test output; only rc and logged are asserted
out="$(run_wrapper forge_label_create audit:demo abcdef owner/repo 2>&1)"
rc=$?
logged="$(cat "$fj_log")"
assert_rc_zero "forge_label_create fj swallows non-zero fj exit" "$rc"
assert_eq "best-effort label failure still uses #-prefixed color" \
  "-H codeberg.org repo labels owner/repo create audit:demo #abcdef" "$logged"

# ---------------------------------------------------------------------------
# Group 2: forge_prompt_label_create — fj rendered command color contract
# ---------------------------------------------------------------------------
echo ""
echo "--- Group 2: forge_prompt_label_create fj rendered color contract ---"
echo ""

echo "Test 5: rendered fj prompt command uses #RRGGBB for bare-hex input"
fj_prompt="$(FORGE_PROVIDER=fj FORGE_HOST=codeberg.org \
  bash -c "source '$SCRIPT_DIR/lib/forge.sh'; forge_prompt_label_create 'audit:demo' 'abcdef' 'owner/repo' ''")"
assert_contains "fj prompt renders #-prefixed color for bare hex" \
  "fj -H codeberg.org repo labels owner/repo create audit:demo #abcdef" "$fj_prompt"

echo ""
echo "Test 6: rendered fj prompt command is idempotent when color already has #"
fj_prompt_prefixed="$(FORGE_PROVIDER=fj FORGE_HOST=codeberg.org \
  bash -c "source '$SCRIPT_DIR/lib/forge.sh'; forge_prompt_label_create 'audit:demo' '#abcdef' 'owner/repo' ''")"
assert_contains "fj prompt preserves caller-supplied # prefix" \
  "fj -H codeberg.org repo labels owner/repo create audit:demo #abcdef" "$fj_prompt_prefixed"
assert_not_contains "fj prompt does not double-prefix #" "##abcdef" "$fj_prompt_prefixed"

echo ""
echo "Test 7: gh and tea rendered commands keep bare hex (no contract change)"
gh_prompt="$(FORGE_PROVIDER=gh \
  bash -c "source '$SCRIPT_DIR/lib/forge.sh'; forge_prompt_label_create 'audit:demo' 'abcdef' 'owner/repo' ''")"
assert_contains "gh prompt keeps bare hex (no # prefix added)" \
  "gh label create audit:demo --color abcdef --force -R owner/repo" "$gh_prompt"
assert_not_contains "gh prompt does not introduce a # prefix" "--color #abcdef" "$gh_prompt"

tea_prompt="$(FORGE_PROVIDER=tea FORGE_PROJECT_PATH=/tmp/x FORGE_REMOTE_NAME=origin \
  bash -c "source '$SCRIPT_DIR/lib/forge.sh'; forge_prompt_label_create 'audit:demo' 'abcdef' 'owner/repo' ''")"
assert_contains "tea prompt keeps bare hex (no # prefix added)" \
  "--color abcdef" "$tea_prompt"
assert_not_contains "tea prompt does not introduce a # prefix" "--color #abcdef" "$tea_prompt"

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
