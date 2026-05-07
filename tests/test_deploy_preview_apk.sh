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

# Tests for issue #90 — Android APK deploy targets must surface target
# details in the existing pre-run confirmation preview before the final
# Proceed? prompt. These tests drive the public repolens.sh CLI; no real
# model, Android SDK tool, adb server, or remote forge is invoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOLENS="$SCRIPT_DIR/repolens.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/deploy-preview-apk.XXXXXX")"
CREATED_LOG_DIRS=()

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below.
_cleanup() {
  rm -rf "$TMPDIR"
  rmdir "$TMPROOT" 2>/dev/null || true
  local d
  for d in "${CREATED_LOG_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap _cleanup EXIT

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected to contain '$needle' in: ${haystack:0:240})"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (unexpected '$needle' present in: ${haystack:0:240})"
  fi
}

assert_line_contains_both() {
  local desc="$1" label="$2" expected="$3" haystack="$4"
  local line
  line="$(printf '%s\n' "$haystack" | grep -F "$label" | head -1 || true)"
  if [[ -n "$line" && "$line" == *"$expected"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected line containing '$label' and '$expected', got: ${line:-<missing>})"
  fi
}

assert_line_matches() {
  local desc="$1" pattern="$2" haystack="$3"
  if printf '%s\n' "$haystack" | grep -Eq "$pattern"; then
    record_pass "$desc"
  else
    record_fail "$desc (expected a line matching /$pattern/ in: ${haystack:0:240})"
  fi
}

assert_before() {
  local desc="$1" first="$2" second="$3" haystack="$4"
  local first_line second_line
  first_line="$(printf '%s\n' "$haystack" | grep -n -F "$first" | head -1 | cut -d: -f1 || true)"
  second_line="$(printf '%s\n' "$haystack" | grep -n -F "$second" | head -1 | cut -d: -f1 || true)"
  if [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected '$first' before '$second'; lines ${first_line:-missing}/${second_line:-missing})"
  fi
}

record_run_id() {
  local log_file="$1" run_id
  run_id="$(grep -oE 'RepoLens run [^ ]+ starting' "$log_file" 2>/dev/null | head -1 | awk '{print $3}' || true)"
  if [[ -n "${run_id:-}" ]]; then
    CREATED_LOG_DIRS+=("$SCRIPT_DIR/logs/$run_id")
  fi
}

# ---------------------------------------------------------------------------
# Fake toolchain
# ---------------------------------------------------------------------------

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'DONE\n'
exit 0
SH
chmod +x "$FAKE_BIN/codex"

write_aapt_package_stub() {
  local package_name="$1"
  cat > "$FAKE_BIN/aapt" <<SH
#!/usr/bin/env bash
printf "%s\n" "package: name='$package_name' versionCode='1' versionName='1.0'"
exit 0
SH
  chmod +x "$FAKE_BIN/aapt"
  rm -f "$FAKE_BIN/aapt2"
}

write_aapt_without_package_stub() {
  cat > "$FAKE_BIN/aapt" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'badging output without package metadata'
exit 0
SH
  chmod +x "$FAKE_BIN/aapt"
  rm -f "$FAKE_BIN/aapt2"
}

write_adb_connected_stub() {
  local device_id="$1"
  local model="${2:-}"
  if [[ -n "$model" ]]; then
    cat > "$FAKE_BIN/adb" <<SH
#!/usr/bin/env bash
cat <<'EOF'
List of devices attached
$device_id          device product:sdk_gphone64_x86_64 model:$model device:emu transport_id:1
EOF
exit 0
SH
  else
    cat > "$FAKE_BIN/adb" <<SH
#!/usr/bin/env bash
cat <<'EOF'
List of devices attached
$device_id          device product:sdk_gphone64_x86_64 device:emu transport_id:1
EOF
exit 0
SH
  fi
  chmod +x "$FAKE_BIN/adb"
}

write_adb_no_device_stub() {
  cat > "$FAKE_BIN/adb" <<'SH'
#!/usr/bin/env bash
cat <<'EOF'
List of devices attached
EOF
exit 0
SH
  chmod +x "$FAKE_BIN/adb"
}

write_build_android_apk_bash_env() {
  local env_file="$1"
  cat > "$env_file" <<'SH'
build_android_apk() {
  [[ -n "${REPOLENS_FAKE_BUILT_APK:-}" ]] || return 1
  printf '%s\n' "$REPOLENS_FAKE_BUILT_APK"
}
SH
}

export PATH="$FAKE_BIN:$PATH"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

APK_PATH="$TMPDIR/app-debug.apk"
: > "$APK_PATH"

PLAIN_DIR="$TMPDIR/plain-server-target"
mkdir -p "$PLAIN_DIR"
printf '%s\n' '# server deploy target' > "$PLAIN_DIR/README.md"

HAVE_SCRIPT=0
if command -v script >/dev/null 2>&1; then
  HAVE_SCRIPT=1
fi

run_deploy_with_pty_to_file() {
  local project="$1" log_file="$2"
  shift 2
  local extra_args="$*"

  : > "$log_file"
  export REPOLENS_TEST_PROJECT="$project"
  set +e
  printf 'y\nn\n' | script -qfec "bash \"$REPOLENS\" --project \"\$REPOLENS_TEST_PROJECT\" --agent codex --mode deploy --local $extra_args" "$log_file" >/dev/null 2>&1
  local rc=$?
  set -e
  record_run_id "$log_file"
  return "$rc"
}

run_deploy_yes_to_file() {
  local project="$1" log_file="$2"

  : > "$log_file"
  set +e
  bash "$REPOLENS" \
    --project "$project" \
    --agent codex \
    --mode deploy \
    --local \
    --yes \
    >"$log_file" 2>&1
  local rc=$?
  set -e
  record_run_id "$log_file"
  return "$rc"
}

echo ""
echo "=== Test Suite: deploy Android pre-run preview (issue #90) ==="
echo ""

if [[ "$HAVE_SCRIPT" -ne 1 ]]; then
  record_fail "script(1) is available for PTY-backed confirmation tests"
else
  record_pass "script(1) is available for PTY-backed confirmation tests"
fi

# ===========================================================================
# Test 1: Android target with connected device shows APK plan before prompt
# ===========================================================================
echo ""
echo "Test 1: Android deploy confirmation shows APK details before Proceed prompt"
write_aapt_package_stub "com.example.preview"
write_adb_connected_stub "emulator-5554" "Pixel_6_API_34"
LOG1="$TMPDIR/run1.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  run_deploy_with_pty_to_file "$APK_PATH" "$LOG1" || true
  out1="$(cat "$LOG1")"

  assert_contains "connected Android run reaches the final abort path" "Aborted." "$out1"
  assert_contains "android preview has an Android APK target heading" "Android APK target" "$out1"
  assert_line_contains_both "android preview shows resolved APK path" "APK:" "$APK_PATH" "$out1"
  assert_line_contains_both "android preview shows detected package name" "Package:" "com.example.preview" "$out1"
  assert_line_contains_both "android preview shows connected device id" "Device:" "emulator-5554" "$out1"
  assert_line_contains_both "android preview shows connected device model" "Device:" "Pixel_6_API_34" "$out1"
  assert_line_matches "android preview names android domain" '^[[:space:]]+Domain:[[:space:]]+android[[:space:]]*$' "$out1"
  assert_line_matches "android preview includes numeric queued lens count" '^[[:space:]]+Lenses:[[:space:]]+[0-9]+[[:space:]]+queued' "$out1"
  assert_line_matches "android-specific preview keeps selected agent visible" '^[[:space:]]+Agent:[[:space:]]+codex[[:space:]]*$' "$out1"
  assert_before "APK plan appears before the final prompt" "APK:" "Proceed?" "$out1"
  assert_before "device status appears before the final prompt" "Device:" "Proceed?" "$out1"
  assert_before "Android-specific agent line appears before the final prompt" "  Agent:" "Proceed?" "$out1"
fi

# ===========================================================================
# Test 2: Android target with no device gives clean no-device messaging
# ===========================================================================
echo ""
echo "Test 2: Android deploy confirmation reports no connected device"
write_aapt_package_stub "com.example.preview"
write_adb_no_device_stub
LOG2="$TMPDIR/run2.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  run_deploy_with_pty_to_file "$APK_PATH" "$LOG2" || true
  out2="$(cat "$LOG2")"

  assert_contains "no-device Android run reaches the final abort path" "Aborted." "$out2"
  assert_line_contains_both "no-device preview still shows APK path" "APK:" "$APK_PATH" "$out2"
  assert_line_contains_both "no-device preview still shows package name" "Package:" "com.example.preview" "$out2"
  assert_line_contains_both "no-device preview says none connected" "Device:" "none connected" "$out2"
  assert_line_contains_both "no-device preview mentions dynamic lens behavior" "Device:" "dynamic" "$out2"
  assert_not_contains "no-device preview does not invent a connected device id" "emulator-5554" "$out2"
  assert_before "no-device message appears before the final prompt" "none connected" "Proceed?" "$out2"
fi

# ===========================================================================
# Test 3: Missing package metadata renders an unknown fallback, not a blank
# ===========================================================================
echo ""
echo "Test 3: Android deploy confirmation handles missing package metadata"
write_aapt_without_package_stub
write_adb_connected_stub "emulator-5556"
LOG3="$TMPDIR/run3.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  run_deploy_with_pty_to_file "$APK_PATH" "$LOG3" || true
  out3="$(cat "$LOG3")"

  assert_contains "unknown-package Android run reaches the final abort path" "Aborted." "$out3"
  assert_line_contains_both "missing package metadata renders as unknown" "Package:" "unknown" "$out3"
  assert_line_contains_both "device without model still shows device id" "Device:" "emulator-5556" "$out3"
  assert_before "unknown package fallback appears before final prompt" "Package:" "Proceed?" "$out3"
fi

# ===========================================================================
# Test 4: APK preview sanitizes control characters in displayed paths
# ===========================================================================
echo ""
echo "Test 4: Android deploy confirmation sanitizes APK path display"
CONTROL_APK_PATH="$TMPDIR/control-character"$'\n'"apk.apk"
SANITIZED_CONTROL_APK_PATH="${CONTROL_APK_PATH//$'\n'/?}"
: > "$CONTROL_APK_PATH"
write_aapt_package_stub "com.example.preview"
write_adb_no_device_stub
LOG4="$TMPDIR/run4.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  run_deploy_with_pty_to_file "$CONTROL_APK_PATH" "$LOG4" || true
  out4="$(cat "$LOG4")"

  assert_contains "control-character Android run reaches the final abort path" "Aborted." "$out4"
  assert_line_contains_both "control-character APK preview uses sanitized path" "APK:" "$SANITIZED_CONTROL_APK_PATH" "$out4"
  assert_before "sanitized APK path appears before the final prompt" "APK:" "Proceed?" "$out4"
fi

# ===========================================================================
# Test 5: Build-helper APK provenance is shown in the preview
# ===========================================================================
echo ""
echo "Test 5: Android deploy confirmation labels APKs built by the helper"
BUILD_SOURCE_DIR="$TMPDIR/android-source-build"
BUILT_APK_DIR="$TMPDIR/helper-built-output"
BUILT_APK_PATH="$BUILT_APK_DIR/app-debug.apk"
BASH_ENV_HELPER="$TMPDIR/build-helper.bashenv"
mkdir -p "$BUILD_SOURCE_DIR" "$BUILT_APK_DIR"
printf '%s\n' 'plugins { id "com.android.application" }' > "$BUILD_SOURCE_DIR/build.gradle"
: > "$BUILT_APK_PATH"
write_build_android_apk_bash_env "$BASH_ENV_HELPER"
write_aapt_package_stub "com.example.preview"
write_adb_no_device_stub
LOG5="$TMPDIR/run5.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  _old_bash_env="${BASH_ENV-}"
  _old_bash_env_set="${BASH_ENV+x}"
  export BASH_ENV="$BASH_ENV_HELPER"
  export REPOLENS_FAKE_BUILT_APK="$BUILT_APK_PATH"
  run_deploy_with_pty_to_file "$BUILD_SOURCE_DIR" "$LOG5" || true
  if [[ -n "$_old_bash_env_set" ]]; then
    export BASH_ENV="$_old_bash_env"
  else
    unset BASH_ENV
  fi
  unset REPOLENS_FAKE_BUILT_APK _old_bash_env _old_bash_env_set
  out5="$(cat "$LOG5")"

  assert_contains "built-helper Android run reaches the final abort path" "Aborted." "$out5"
  assert_line_contains_both "built-helper preview shows built APK path" "APK:" "$BUILT_APK_PATH" "$out5"
  assert_contains "built-helper preview labels build provenance" "(built from source via gradlew assembleDebug)" "$out5"
  assert_before "build provenance appears before the final prompt" "built from source via gradlew assembleDebug" "Proceed?" "$out5"
fi

# ===========================================================================
# Test 6: --yes skips the confirmation prompt and Android preview entirely
# ===========================================================================
echo ""
echo "Test 6: --yes skips prompts and the Android preview block"
write_aapt_package_stub "com.example.preview"
write_adb_connected_stub "emulator-5554" "Pixel_6_API_34"
LOG6="$TMPDIR/run6.log"
run_deploy_yes_to_file "$APK_PATH" "$LOG6" || true
out6="$(cat "$LOG6")"

assert_not_contains "--yes skips deploy authorization prompt" "I confirm I am authorized to audit this server" "$out6"
assert_not_contains "--yes skips final Proceed prompt" "Proceed? [y/N]" "$out6"
assert_not_contains "--yes skips Android preview heading" "Android APK target" "$out6"
assert_not_contains "--yes skips Android APK preview line" "APK:" "$out6"
assert_not_contains "--yes skips Android package preview line" "Package:" "$out6"
assert_not_contains "--yes skips Android device preview line" "Device:" "$out6"

# ===========================================================================
# Test 7: Server deploy confirmation remains free of Android-only preview
# ===========================================================================
echo ""
echo "Test 7: server deploy confirmation does not show Android APK preview"
write_aapt_package_stub "com.example.preview"
write_adb_connected_stub "emulator-5554" "Pixel_6_API_34"
LOG7="$TMPDIR/run7.log"
if [[ "$HAVE_SCRIPT" -eq 1 ]]; then
  run_deploy_with_pty_to_file "$PLAIN_DIR" "$LOG7" || true
  out7="$(cat "$LOG7")"

  assert_contains "server confirmation still reaches final prompt" "Proceed? [y/N]" "$out7"
  assert_contains "server confirmation aborts cleanly on no answer" "Aborted." "$out7"
  assert_not_contains "server confirmation does not show Android heading" "Android APK target" "$out7"
  assert_not_contains "server confirmation does not show APK label" "APK:" "$out7"
  assert_not_contains "server confirmation does not show package label" "Package:" "$out7"
  assert_not_contains "server confirmation does not show device label" "Device:" "$out7"
  assert_not_contains "server confirmation does not show android domain line" "Domain:     android" "$out7"
fi

echo ""
echo "================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "================================"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
