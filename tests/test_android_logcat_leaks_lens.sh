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

# Tests for issue #100 - Android logcat sensitive-data leak lens.
#
# Behavioural contract:
#   - android/logcat-leaks exists and is registered in config/domains.json.
#   - The prompt covers sensitive logcat evidence named in the issue.
#   - Dynamic work is gated on ANDROID_HAS_DEVICE and uses read-only adb.
#   - Host-side log capture uses a private scratch directory and redaction.
#   - Examples avoid active device/app mutation commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/android/logcat-leaks.md"
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
echo "=== Test Suite: Android logcat sensitive-data leak lens (issue #100) ==="
echo ""

echo "Test 1: lens file exists"
if [[ -f "$LENS_FILE" ]]; then
  record_pass "logcat-leaks lens file exists"
else
  record_fail "logcat-leaks lens file exists"
fi

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

echo ""
echo "Test 2: frontmatter is complete"
assert_contains "id frontmatter" "id: logcat-leaks" "$lens_content"
assert_contains "domain frontmatter" "domain: android" "$lens_content"
assert_contains "name frontmatter" "name: Logcat Sensitive-Data Leak Auditor" "$lens_content"
assert_contains "role frontmatter" "role: Android Logcat Forensic Analyst" "$lens_content"

echo ""
echo "Test 3: lens is registered under android deploy domain"
android_lenses="$(jq -r '.domains[] | select(.id == "android") | .lenses[]' "$DOMAINS_FILE")"
assert_contains "registered android lens list includes logcat-leaks" "logcat-leaks" "$android_lenses"

echo ""
echo "Test 4: issue leak families are covered"
for term in \
  "Authorization: Bearer" \
  "Set-Cookie" \
  "OAuth" \
  "refresh token" \
  "password" \
  "PII" \
  "GPS/location coordinates" \
  "request/response bodies" \
  "stack traces" \
  "SQL statements" \
  "card/CVV/payment data" \
  "AES keys/IVs" \
  "Firebase" \
  "Amplitude" \
  "Crashlytics" \
  "Sentry" \
  "Stripe" \
  "Braintree" \
  "deep-link params" \
  "User{" \
  "Account{" \
  "Session{"; do
  assert_contains "covers $term" "$term" "$lens_content"
done

echo ""
echo "Test 5: runtime commands use safe Android variables and read-only logcat"
assert_contains "assigns runtime APK path to local variable" 'apk_path=${ANDROID_APK_PATH:?ANDROID_APK_PATH is required}' "$lens_content"
assert_contains "checks quoted APK path exists" '[ -f "$apk_path" ]' "$lens_content"
assert_contains "assigns package name to local variable" 'package_name=${ANDROID_PACKAGE_NAME:-unknown}' "$lens_content"
assert_contains "gates dynamic work on Android device availability" '{{ANDROID_HAS_DEVICE}}' "$lens_content"
assert_contains "uses read-only device inventory" "adb devices -l" "$lens_content"
assert_contains "uses read-only dumpsys package" 'adb shell dumpsys package "$package_name"' "$lens_content"
assert_contains "captures existing logcat buffer" 'adb logcat -d > "$logcat_file"' "$lens_content"
assert_contains "optionally filters by existing PID" 'adb logcat -d --pid="$pid"' "$lens_content"
assert_contains "uses quoted APK variable for badging" 'aapt dump badging "$apk_path"' "$lens_content"
assert_not_contains "does not quote template APK path in commands" '"{{ANDROID_APK_PATH}}"' "$lens_content"

echo ""
echo "Test 6: host log capture uses private scratch output and redaction"
assert_contains "sets restrictive umask for scratch tree" 'umask 077' "$lens_content"
assert_contains "creates unique scratch directory" 'scratch_dir="$(mktemp -d)"' "$lens_content"
assert_contains "places logcat capture under scratch tree" 'logcat_file="$scratch_dir/logcat.txt"' "$lens_content"
assert_contains "cleans logcat scratch output" 'rm -rf -- "$scratch_dir"' "$lens_content"
assert_contains "requires redaction of full values" "redact full values" "$lens_content"
assert_not_contains "does not use fixed logcat shared path" "/tmp/logcat" "$lens_content"
assert_not_contains "does not use any hard-coded tmp directory" "/tmp/" "$lens_content"

echo ""
echo "Test 7: examples avoid active device and app mutation commands"
for forbidden in \
  "adb logcat -c" \
  "adb shell am start" \
  "adb install" \
  "pm clear" \
  "am force-stop" \
  "settings put" \
  "adb push" \
  "input tap"; do
  assert_not_contains "does not mention $forbidden" "$forbidden" "$lens_content"
done

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
