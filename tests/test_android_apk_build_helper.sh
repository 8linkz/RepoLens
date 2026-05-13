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

# Tests for issue #187 — Android APK build helpers.
#
# Behavioural contract:
#   - lib/android.sh exports android_project_appears_buildable <project_path>.
#   - The buildable classifier only checks shallow Android/Gradle markers.
#   - lib/android.sh exports build_android_apk <project_path>.
#   - The build helper runs exactly ./gradlew assembleDebug from the project
#     root, keeps Gradle stdout off helper stdout, preserves Gradle stderr,
#     then prints only the rediscovered APK path on success.
#   - Build failures and successful builds with no APK return non-zero without
#     emitting an APK path on stdout.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_LIB="$SCRIPT_DIR/lib/android.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/android-apk-build-helper.XXXXXX")"
trap 'rm -rf "$TMPDIR"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT

BUILD_STDOUT_FILE="$TMPDIR/build-stdout.txt"
BUILD_STDERR_FILE="$TMPDIR/build-stderr.txt"
LOG_INFO_FILE="$TMPDIR/log-info.txt"
LOG_WARN_FILE="$TMPDIR/log-warn.txt"
LOG_ERROR_FILE="$TMPDIR/log-error.txt"

BUILD_RC=0
BUILD_OUTPUT=""
BUILD_ERR=""
LOG_INFO_MESSAGES=""

record_pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

record_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected to contain '$needle', got '${haystack:0:240}')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected not to contain '$needle', got '${haystack:0:240}')"
  fi
}

assert_rc_zero() {
  local desc="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected rc=0, got rc=$rc)"
  fi
}

assert_rc_nonzero() {
  local desc="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected non-zero rc, got rc=0)"
  fi
}

# shellcheck disable=SC2329  # Indirectly invoked by sourced Android helpers.
log_info() {
  printf '%s\n' "$*" >> "$LOG_INFO_FILE"
}

# shellcheck disable=SC2329  # Reserved for helper implementations that warn.
log_warn() {
  printf '%s\n' "$*" >> "$LOG_WARN_FILE"
}

# shellcheck disable=SC2329  # Reserved for helper implementations that error.
log_error() {
  printf '%s\n' "$*" >> "$LOG_ERROR_FILE"
}

if [[ -f "$ANDROID_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$ANDROID_LIB"
fi

require_android_project_appears_buildable() {
  local desc="$1"
  if declare -F android_project_appears_buildable >/dev/null 2>&1; then
    return 0
  fi
  record_fail "$desc (android_project_appears_buildable is not defined)"
  return 1
}

require_build_android_apk() {
  local desc="$1"
  if declare -F build_android_apk >/dev/null 2>&1; then
    return 0
  fi
  record_fail "$desc (build_android_apk is not defined)"
  return 1
}

assert_buildable_success() {
  local desc="$1" project="$2"
  if android_project_appears_buildable "$project"; then
    record_pass "$desc"
  else
    record_fail "$desc (expected success)"
  fi
}

assert_buildable_failure() {
  local desc="$1" project="${2-__NO_ARG__}"
  if [[ "$project" == "__NO_ARG__" ]]; then
    if android_project_appears_buildable; then
      record_fail "$desc (expected non-zero)"
    else
      record_pass "$desc"
    fi
  elif android_project_appears_buildable "$project"; then
    record_fail "$desc (expected non-zero)"
  else
    record_pass "$desc"
  fi
}

run_build() {
  local project_arg="$1" cwd="${2:-$SCRIPT_DIR}"

  : > "$LOG_INFO_FILE"
  : > "$LOG_WARN_FILE"
  : > "$LOG_ERROR_FILE"
  : > "$BUILD_STDOUT_FILE"
  : > "$BUILD_STDERR_FILE"

  (
    cd "$cwd" || exit 99
    build_android_apk "$project_arg"
  ) >"$BUILD_STDOUT_FILE" 2>"$BUILD_STDERR_FILE"
  BUILD_RC=$?
  BUILD_OUTPUT="$(cat "$BUILD_STDOUT_FILE")"
  BUILD_ERR="$(cat "$BUILD_STDERR_FILE")"
  LOG_INFO_MESSAGES="$(cat "$LOG_INFO_FILE")"
}

write_gradlew_success() {
  local project="$1" record_pwd="$2" record_args="$3" apk_relpath="$4"
  cat > "$project/gradlew" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$PWD" > "$record_pwd"
printf '%s\n' "\$*" > "$record_args"
printf '%s\n' 'gradle stdout must not appear on helper stdout'
printf '%s\n' 'gradle stderr remains visible' >&2
mkdir -p "\$(dirname "$apk_relpath")"
: > "$apk_relpath"
exit 0
SH
  chmod +x "$project/gradlew"
}

write_gradlew_failure() {
  local project="$1"
  cat > "$project/gradlew" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'gradle failed before producing an APK' >&2
printf '%s\n' 'failing gradle stdout must not appear on helper stdout'
exit 42
SH
  chmod +x "$project/gradlew"
}

write_gradlew_no_apk() {
  local project="$1"
  cat > "$project/gradlew" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'gradle stdout from no-apk build'
printf '%s\n' 'gradle stderr from no-apk build' >&2
exit 0
SH
  chmod +x "$project/gradlew"
}

echo ""
echo "=== Test Suite: Android APK build helpers (issue #187) ==="
echo ""

echo "Test 1: lib/android.sh exports the Android build helper API"
if [[ -f "$ANDROID_LIB" ]]; then
  record_pass "lib/android.sh exists"
else
  record_fail "lib/android.sh exists"
fi
if declare -F android_project_appears_buildable >/dev/null 2>&1; then
  record_pass "android_project_appears_buildable is defined"
else
  record_fail "android_project_appears_buildable is defined"
fi
if declare -F build_android_apk >/dev/null 2>&1; then
  record_pass "build_android_apk is defined"
else
  record_fail "build_android_apk is defined"
fi

echo ""
echo "Test 2: buildable classifier accepts only shallow Android/Gradle markers"
if require_android_project_appears_buildable "shallow Android/Gradle markers can be classified"; then
  for marker in gradlew build.gradle build.gradle.kts app/build.gradle app/build.gradle.kts; do
    project="$TMPDIR/buildable-${marker//\//-}"
    mkdir -p "$(dirname "$project/$marker")"
    : > "$project/$marker"
    assert_buildable_success "accepts shallow marker $marker" "$project"
  done

  empty_project="$TMPDIR/empty-project"
  missing_project="$TMPDIR/missing-project"
  file_project="$TMPDIR/not-a-directory"
  nested_gradle="$TMPDIR/nested-gradle"
  nested_app_gradle="$TMPDIR/nested-app-gradle"
  mkdir -p "$empty_project" "$nested_gradle/nested" "$nested_app_gradle/src/app"
  : > "$file_project"
  : > "$nested_gradle/nested/build.gradle"
  : > "$nested_app_gradle/src/app/build.gradle"

  assert_buildable_failure "empty argument is not buildable" ""
  assert_buildable_failure "missing argument is not buildable"
  assert_buildable_failure "missing path is not buildable" "$missing_project"
  assert_buildable_failure "file path is not buildable" "$file_project"
  assert_buildable_failure "empty directory is not buildable" "$empty_project"
  assert_buildable_failure "nested build.gradle is not a shallow marker" "$nested_gradle"
  assert_buildable_failure "nested app/build.gradle is not a shallow marker" "$nested_app_gradle"
fi

echo ""
echo "Test 3: successful build runs ./gradlew assembleDebug from project root"
if require_build_android_apk "successful build can invoke Gradle wrapper"; then
  project="$TMPDIR/successful-build"
  mkdir -p "$project"
  record_pwd="$TMPDIR/success-record-pwd.txt"
  record_args="$TMPDIR/success-record-args.txt"
  expected_apk="$project/app/build/outputs/apk/debug/app-debug.apk"
  write_gradlew_success "$project" "$record_pwd" "$record_args" "app/build/outputs/apk/debug/app-debug.apk"

  run_build "$(basename "$project")" "$TMPDIR"
  actual_pwd="$(cat "$record_pwd" 2>/dev/null || true)"
  actual_args="$(cat "$record_args" 2>/dev/null || true)"

  assert_rc_zero "successful build returns rc=0" "$BUILD_RC"
  assert_eq "successful build prints only the rediscovered APK path" "$expected_apk" "$BUILD_OUTPUT"
  assert_eq "Gradle wrapper runs from canonical project root" "$project" "$actual_pwd"
  assert_eq "Gradle wrapper receives only assembleDebug" "assembleDebug" "$actual_args"
  assert_contains "Gradle stderr remains visible" "gradle stderr remains visible" "$BUILD_ERR"
  assert_not_contains "Gradle stdout does not corrupt helper stdout" "gradle stdout must not appear" "$BUILD_OUTPUT"
  assert_contains "rediscovered APK is logged through discovery" "$expected_apk" "$LOG_INFO_MESSAGES"
fi

echo ""
echo "Test 4: missing wrapper returns non-zero without stdout"
if require_build_android_apk "missing wrapper can fail cleanly"; then
  project="$TMPDIR/missing-wrapper"
  mkdir -p "$project"

  run_build "$project"
  assert_rc_nonzero "missing wrapper returns non-zero" "$BUILD_RC"
  assert_eq "missing wrapper prints no stdout" "" "$BUILD_OUTPUT"
  assert_contains "missing wrapper exposes shell error" "No such file or directory" "$BUILD_ERR"
fi

echo ""
echo "Test 5: non-executable wrapper returns non-zero and exposes shell stderr"
if require_build_android_apk "non-executable wrapper can fail cleanly"; then
  project="$TMPDIR/non-executable-wrapper"
  mkdir -p "$project"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$project/gradlew"
  chmod 0644 "$project/gradlew"

  run_build "$project"
  assert_rc_nonzero "non-executable wrapper returns non-zero" "$BUILD_RC"
  assert_eq "non-executable wrapper prints no stdout" "" "$BUILD_OUTPUT"
  assert_contains "non-executable wrapper exposes shell error" "Permission denied" "$BUILD_ERR"
fi

echo ""
echo "Test 6: failing Gradle invocation returns non-zero and preserves stderr"
if require_build_android_apk "failing Gradle invocation can fail cleanly"; then
  project="$TMPDIR/failing-wrapper"
  mkdir -p "$project"
  write_gradlew_failure "$project"

  run_build "$project"
  assert_rc_nonzero "failing Gradle returns non-zero" "$BUILD_RC"
  assert_eq "failing Gradle prints no stdout path" "" "$BUILD_OUTPUT"
  assert_contains "failing Gradle stderr remains visible" "gradle failed before producing an APK" "$BUILD_ERR"
  assert_not_contains "failing Gradle stdout does not leak to helper stdout" "failing gradle stdout" "$BUILD_OUTPUT"
fi

echo ""
echo "Test 7: successful Gradle with no APK reports rediscovery failure"
if require_build_android_apk "successful Gradle with no APK can fail cleanly"; then
  project="$TMPDIR/no-apk-after-build"
  mkdir -p "$project"
  write_gradlew_no_apk "$project"

  run_build "$project"
  assert_rc_nonzero "successful Gradle with no APK returns non-zero" "$BUILD_RC"
  assert_eq "successful Gradle with no APK prints no stdout path" "" "$BUILD_OUTPUT"
  assert_contains "successful Gradle with no APK preserves Gradle stderr" "gradle stderr from no-apk build" "$BUILD_ERR"
  assert_contains "successful Gradle with no APK reports missing artifact" "assembleDebug succeeded but no APK was discovered" "$BUILD_ERR"
fi

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
