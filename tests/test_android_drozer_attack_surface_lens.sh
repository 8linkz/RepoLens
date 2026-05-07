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

# Tests for issue #104 - Android drozer attack surface lens.
#
# Behavioural contract:
#   - android/drozer-attack-surface exists and is registered in config/domains.json.
#   - The Android base prompt explicitly allows only this lens's narrow drozer
#     active IPC probes.
#   - The lens gates drozer work on ANDROID_HAS_DEVICE, drozer CLI availability,
#     drozer-agent setup, and package context.
#   - Examples avoid destructive device/app/provider mutation commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LENS_FILE="$SCRIPT_DIR/prompts/lenses/android/drozer-attack-surface.md"
ANDROID_BASE="$SCRIPT_DIR/prompts/_base/android.md"
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
echo "=== Test Suite: Android drozer attack surface lens (issue #104) ==="
echo ""

echo "Test 1: lens file and Android base prompt exist"
if [[ -f "$LENS_FILE" ]]; then
  record_pass "drozer-attack-surface lens file exists"
else
  record_fail "drozer-attack-surface lens file exists"
fi

if [[ -f "$ANDROID_BASE" ]]; then
  record_pass "android base prompt exists"
else
  record_fail "android base prompt exists"
fi

lens_content=""
if [[ -f "$LENS_FILE" ]]; then
  lens_content="$(cat "$LENS_FILE")"
fi

base_content=""
if [[ -f "$ANDROID_BASE" ]]; then
  base_content="$(cat "$ANDROID_BASE")"
fi

echo ""
echo "Test 2: frontmatter is complete"
assert_contains "id frontmatter" "id: drozer-attack-surface" "$lens_content"
assert_contains "domain frontmatter" "domain: android" "$lens_content"
assert_contains "name frontmatter" "name: Drozer Attack Surface Auditor" "$lens_content"
assert_contains "role frontmatter" "role: Drozer Mobile Pentest Operator" "$lens_content"

echo ""
echo "Test 3: lens is registered under android deploy domain"
android_lenses="$(jq -r '.domains[] | select(.id == "android") | .lenses[]' "$DOMAINS_FILE")"
assert_contains "registered android lens list includes drozer-attack-surface" "drozer-attack-surface" "$android_lenses"

echo ""
echo "Test 4: Android base prompt has a drozer active IPC exception"
assert_contains "base names the drozer exception" 'android/drozer-attack-surface' "$base_content"
assert_contains "base gates drozer exception on device availability" '{{ANDROID_HAS_DEVICE}}' "$base_content"
assert_contains "base requires authorized drozer IPC probing" "authorized for active Android drozer IPC probing" "$base_content"
assert_contains "base permits drozer attack surface enumeration" 'run app.package.attacksurface "$package_name"' "$base_content"
assert_contains "base permits provider read probes" 'run app.provider.read content://<authority>/<path>' "$base_content"
assert_contains "base permits provider query probes" 'run app.provider.query content://<authority>/<path> --selection "1=1"' "$base_content"
assert_contains "base permits activity component probes" 'run app.activity.start --component "$package_name" "<activity-class>"' "$base_content"
assert_contains "base permits service component probes" 'run app.service.start --component "$package_name" "<service-class>"' "$base_content"
assert_contains "base permits broadcast probes" 'run app.broadcast.send --action "<action>"' "$base_content"
assert_contains "base keeps destructive mutations forbidden" "This exception does not permit any other active or mutating device/app operation" "$base_content"
assert_contains "base requires stopping on stateful side effects" "stop active probing immediately" "$base_content"

echo ""
echo "Test 5: lens aligns with setup gates and base exception"
assert_contains "lens references base drozer exception" "Active drozer probes are allowed only under the base Android prompt" "$lens_content"
assert_contains "lens gates dynamic work on Android device availability" '{{ANDROID_HAS_DEVICE}}' "$lens_content"
assert_contains "lens checks drozer CLI availability" "command -v drozer" "$lens_content"
assert_contains "lens references drozer-agent setup" "drozer-agent.apk" "$lens_content"
assert_contains "lens skips cleanly when setup is missing" "no device or drozer-agent missing - skipped" "$lens_content"
assert_contains "lens assigns package name to local variable" 'package_name=${ANDROID_PACKAGE_NAME:-unknown}' "$lens_content"
assert_contains "lens requires authorized audit context" "already-authorized Android audit context" "$lens_content"
assert_contains "lens requires stopping on stateful side effects" "stop active probing immediately" "$lens_content"

echo ""
echo "Test 6: issue drozer risk areas are covered"
for term in \
  "app.package.attacksurface" \
  "app.activity.info" \
  "app.service.info" \
  "app.broadcast.info" \
  "app.provider.info" \
  "app.provider.read" \
  "app.provider.query" \
  "app.activity.start --component" \
  "app.service.start" \
  "app.broadcast.send" \
  "app.package.backup" \
  "app.package.shareduid" \
  "ContentProvider" \
  "BroadcastReceiver" \
  "Binder.getCallingUid" \
  "android:sharedUserId" \
  "allowBackup" \
  "debuggable"; do
  assert_contains "covers $term" "$term" "$lens_content"
done

echo ""
echo "Test 7: investigation commands use safe Android variables and private scratch"
assert_contains "assigns runtime APK path to local variable" 'apk_path=${ANDROID_APK_PATH:?ANDROID_APK_PATH is required}' "$lens_content"
assert_contains "checks quoted APK path exists" '[ -f "$apk_path" ]' "$lens_content"
assert_contains "uses quoted APK variable for file" 'file "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for unzip inventory" 'unzip -l "$apk_path"' "$lens_content"
assert_contains "uses quoted APK variable for manifest xmltree" 'aapt dump xmltree "$apk_path" AndroidManifest.xml' "$lens_content"
assert_contains "sets restrictive umask for scratch tree" 'umask 077' "$lens_content"
assert_contains "creates unique scratch directory" 'scratch_dir="$(mktemp -d)"' "$lens_content"
assert_contains "places drozer output under scratch tree" 'drozer_out="$scratch_dir/drozer"' "$lens_content"
assert_contains "cleans scratch output" 'rm -rf -- "$scratch_dir"' "$lens_content"
assert_not_contains "does not quote template APK path in commands" '"{{ANDROID_APK_PATH}}"' "$lens_content"
assert_not_contains "does not use any hard-coded tmp directory" "/tmp/" "$lens_content"

echo ""
echo "Test 8: adjacent-lens deduplication is explicit"
for lens in \
  "manifest-audit" \
  "exported-components" \
  "intent-filters" \
  "intent-fuzzing"; do
  assert_contains "deduplicates $lens" "$lens" "$lens_content"
done

echo ""
echo "Test 9: examples avoid destructive device, app, and provider mutation commands"
for forbidden in \
  "app.provider.insert" \
  "app.provider.update" \
  "app.provider.delete" \
  "adb install" \
  "pm clear" \
  "pm uninstall" \
  "am force-stop" \
  "settings put" \
  "adb push" \
  "input tap" \
  "content insert" \
  "content update" \
  "content delete"; do
  assert_not_contains "does not mention $forbidden" "$forbidden" "$lens_content"
done

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
