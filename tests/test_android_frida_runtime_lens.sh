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

# Tests for issue #102 - Android Frida runtime behavior lens.
#
# Behavioural contract:
#   - android/frida-runtime exists and is registered in config/domains.json.
#   - The prompt covers runtime crypto, file I/O, network, process,
#     reflection, hidden API, IPC, and logging behavior named in the issue.
#   - Dynamic work is gated on ANDROID_HAS_DEVICE and attaches only to an
#     already-running app process.
#   - Host-side hook scripts and trace output use a private scratch directory.
#   - Examples avoid device/app mutation and Frida spawn commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/android/frida-runtime.md"
DOMAINS_FILE="$SCRIPT_DIR/config/domains.json"

PASS=0
FAIL=0
TOTAL=0

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
    record_fail "$desc (missing '$needle')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (should not contain '$needle')"
  fi
}

echo ""
echo "=== Test Suite: Android Frida runtime behavior lens (issue #102) ==="
echo ""

echo "Test 1: lens file exists"
if [[ -f "$LENS_FILE" ]]; then
  record_pass "frida-runtime lens file exists"
else
  record_fail "frida-runtime lens file exists"
fi

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 2: frontmatter is complete"
assert_contains "id frontmatter" "id: frida-runtime" "$lens_content"
assert_contains "domain frontmatter" "domain: android" "$lens_content"
assert_contains "name frontmatter" "name: Frida Runtime Behavior Auditor" "$lens_content"
assert_contains "role frontmatter" "role: Mobile Runtime Hooking Specialist" "$lens_content"

echo ""
echo "Test 3: lens is registered under android deploy domain"
android_lenses="$(jq -r '.domains[] | select(.id == "android") | .lenses[]' "$DOMAINS_FILE")"
assert_contains "registered android lens list includes frida-runtime" "frida-runtime" "$android_lenses"

echo ""
echo "Test 4: issue runtime behavior families are covered"
for term in \
  "Cipher.getInstance" \
  "AES/ECB" \
  "AES/CBC" \
  "MessageDigest.getInstance" \
  "MD5" \
  "SHA-1" \
  "PBKDF2" \
  "PBEKeySpec" \
  "FileOutputStream" \
  "/sdcard" \
  "HostnameVerifier" \
  "X509TrustManager" \
  "Runtime.exec" \
  "ProcessBuilder" \
  "Class.forName" \
  "Method.invoke" \
  "VMRuntime.setHiddenApiExemptions" \
  "bindService" \
  "Log.d" \
  "Log.i" \
  "Log.v" \
  "frida" \
  "frida-server" \
  "objection"; do
  assert_contains "covers $term" "$term" "$lens_content"
done

echo ""
echo "Test 5: runtime commands use safe Android variables"
assert_contains "assigns runtime APK path to local variable" 'apk_path=${ANDROID_APK_PATH:?ANDROID_APK_PATH is required}' "$lens_content"
assert_contains "checks quoted APK path exists" '[ -f "$apk_path" ]' "$lens_content"
assert_contains "assigns package name to local variable" 'package_name=${ANDROID_PACKAGE_NAME:-unknown}' "$lens_content"
assert_contains "gates dynamic work on Android device availability" '{{ANDROID_HAS_DEVICE}}' "$lens_content"
assert_contains "uses read-only device inventory" "adb devices -l" "$lens_content"
assert_contains "uses read-only dumpsys package" 'adb shell dumpsys package "$package_name"' "$lens_content"
assert_contains "uses quoted APK variable for badging" 'aapt dump badging "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for unzip inventory" 'unzip -l "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for DEX streaming" 'unzip -p "$apk_path" classes.dex | strings' "$lens_content"
assert_not_contains "does not quote template APK path in commands" '"{{ANDROID_APK_PATH}}"' "$lens_content"

echo ""
echo "Test 6: hook output uses private scratch output"
assert_contains "sets restrictive umask for scratch tree" 'umask 077' "$lens_content"
assert_contains "creates unique scratch directory" 'scratch_dir="$(mktemp -d)"' "$lens_content"
assert_contains "places apktool output under scratch tree" 'apktool_out="$scratch_dir/apktool"' "$lens_content"
assert_contains "places jadx output under scratch tree" 'jadx_out="$scratch_dir/jadx"' "$lens_content"
assert_contains "places trace log under scratch tree" 'trace_log="$scratch_dir/frida-runtime.log"' "$lens_content"
assert_contains "places hook script under scratch tree" 'hook_js="$scratch_dir/frida-runtime-observe.js"' "$lens_content"
assert_contains "cleans scratch output" 'rm -rf -- "$scratch_dir"' "$lens_content"
assert_not_contains "does not use any hard-coded tmp directory" "/tmp/" "$lens_content"

echo ""
echo "Test 7: Frida examples attach to existing process"
assert_contains "checks existing Frida process list" 'frida-ps -U | grep -F "$package_name"' "$lens_content"
assert_contains "uses attach-only Frida command" 'frida -U -n "$package_name" -l "$hook_js"' "$lens_content"
assert_contains "mentions attach-only frida-trace usage" "attach only to the existing process by name or PID" "$lens_content"
assert_contains "requires already-running app process" "already-running app process" "$lens_content"

echo ""
echo "Test 8: examples avoid active device and app mutation commands"
for forbidden in \
  "adb logcat -c" \
  "adb shell am start" \
  "adb install" \
  "adb push" \
  "adb root" \
  "pm clear" \
  "am force-stop" \
  "settings put" \
  "input tap" \
  "frida -U -f" \
  "frida-trace -f" \
  "--no-pause" \
  "Interceptor.replace"; do
  assert_not_contains "does not mention $forbidden" "$forbidden" "$lens_content"
done

echo ""
echo "Test 9: reporting requires redaction and no setup-only findings"
for sensitive in \
  "tokens" \
  "cookies" \
  "passwords" \
  "keys" \
  "PII" \
  "payment data" \
  "request/response bodies" \
  "file contents"; do
  assert_contains "requires redaction for $sensitive" "$sensitive" "$lens_content"
done
assert_contains "does not file missing setup as a vulnerability" "Do not file vulnerability issues for missing Frida" "$lens_content"
assert_contains "outputs setup limitation when dynamic evidence unavailable" "setup limitation" "$lens_content"

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
