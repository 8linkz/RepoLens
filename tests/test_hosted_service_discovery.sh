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

# Regression tests for hosted discovery. Issue #83 covers scanner-reachable
# container ports; issue #85 covers hosted OpenAPI/Swagger spec detection.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/hosted.sh"

PASS=0
FAIL=0
TOTAL=0

TMPROOT="$SCRIPT_DIR/tests/.tmp"
mkdir -p "$TMPROOT"
TMPDIR="$(mktemp -d "$TMPROOT/hosted-service-discovery.XXXXXX")"
trap 'rm -rf "$TMPDIR"; rmdir "$TMPROOT" 2>/dev/null || true' EXIT

DOCKER_CALL_LOG="$TMPDIR/docker-calls.log"
DOCKER_PS_JSON=""
DOCKER_PS_RC=0
DOCKER_PS_Q_OUTPUT=""
DOCKER_PS_Q_RC=0
DOCKER_INSPECT_RC=0
DOCKER_INSPECT_FORMAT_OUTPUT=""
DOCKER_INSPECT_JSON_OUTPUT=""
DOCKER_RUN_RESPONSES=""
LOG_WARN_MESSAGES=""
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
    record_fail "$desc (did not expect '$needle')"
  fi
}

assert_zero_rc() {
  local desc="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    record_pass "$desc"
  else
    record_fail "$desc (expected rc=0, got rc=$rc)"
  fi
}

set_docker_run_response() {
  local service="$1" port="$2" output="$3" rc="$4"
  local encoded_output="${output//$'\n'/__REPOLENS_TEST_NEWLINE__}"
  DOCKER_RUN_RESPONSES="${DOCKER_RUN_RESPONSES}${service}|${port}|/|${encoded_output}|${rc}"$'\n'
}

set_docker_run_response_for_path() {
  local service="$1" port="$2" path="$3" output="$4" rc="$5"
  local encoded_output="${output//$'\n'/__REPOLENS_TEST_NEWLINE__}"
  DOCKER_RUN_RESPONSES="${DOCKER_RUN_RESPONSES}${service}|${port}|${path}|${encoded_output}|${rc}"$'\n'
}

reset_docker_stub() {
  DOCKER_PS_JSON=""
  DOCKER_PS_RC=0
  DOCKER_PS_Q_OUTPUT=""
  DOCKER_PS_Q_RC=0
  DOCKER_INSPECT_RC=0
  DOCKER_INSPECT_FORMAT_OUTPUT=""
  DOCKER_INSPECT_JSON_OUTPUT=""
  DOCKER_RUN_RESPONSES=""
  LOG_WARN_MESSAGES=""
  LOG_INFO_MESSAGES=""
  : > "$DOCKER_CALL_LOG"
  HOSTED_NETWORK="issue83_default"
  HOSTED_SERVICES=""
  HOSTED_SERVICES_DETAIL=""
  HOSTED_API_SPECS_DETAIL=""
  HOSTED_API_SPEC_MAX_BODY_BYTES=262144
}

# shellcheck disable=SC2329  # Indirectly invoked by sourced hosted helpers.
log_warn() {
  LOG_WARN_MESSAGES="${LOG_WARN_MESSAGES}${1}"$'\n'
}

# shellcheck disable=SC2329  # Indirectly invoked by sourced hosted helpers.
log_info() {
  LOG_INFO_MESSAGES="${LOG_INFO_MESSAGES}${1}"$'\n'
}

# shellcheck disable=SC2329  # Indirectly invoked by sourced hosted helpers.
docker() {
  printf '%s\n' "$*" >> "$DOCKER_CALL_LOG"

  if [[ "${1:-}" == "compose" ]]; then
    if [[ "${2:-}" == "version" ]]; then
      return 0
    fi
    if [[ "$*" == *" ps "* && "$*" == *"--format json"* ]]; then
      printf '%s\n' "$DOCKER_PS_JSON"
      return "$DOCKER_PS_RC"
    fi
    if [[ "$*" == *" ps -q"* ]]; then
      printf '%s\n' "$DOCKER_PS_Q_OUTPUT"
      return "$DOCKER_PS_Q_RC"
    fi
  fi

  if [[ "${1:-}" == "inspect" ]]; then
    if [[ "$DOCKER_INSPECT_RC" -ne 0 ]]; then
      return "$DOCKER_INSPECT_RC"
    fi
    if [[ "$*" == *"--format"* ]]; then
      printf '%s\n' "$DOCKER_INSPECT_FORMAT_OUTPUT"
    else
      printf '%s\n' "$DOCKER_INSPECT_JSON_OUTPUT"
    fi
    return 0
  fi

  if [[ "${1:-}" == "run" ]]; then
    local url="${!#}" service port path rule_service rule_port rule_path rule_output rule_rc
    if [[ "$url" =~ ^http://([^:/]+):([0-9]+)(/[^[:space:]]*)?$ ]]; then
      service="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[2]}"
      path="${BASH_REMATCH[3]:-/}"
      while IFS='|' read -r rule_service rule_port rule_path rule_output rule_rc; do
        [[ -z "$rule_service" ]] && continue
        if [[ "$rule_service" == "$service" && "$rule_port" == "$port" && "$rule_path" == "$path" ]]; then
          rule_output="${rule_output//__REPOLENS_TEST_NEWLINE__/$'\n'}"
          printf '%s' "$rule_output"
          return "${rule_rc:-0}"
        fi
      done <<< "$DOCKER_RUN_RESPONSES"
    fi
    printf '000'
    return 7
  fi

  echo "unexpected docker invocation: $*" >&2
  return 127
}

run_discovery() {
  discover_services "$TMPDIR/compose.yml" "issue83"
}

docker_calls() {
  cat "$DOCKER_CALL_LOG"
}

echo ""
echo "=== Test Suite: hosted service discovery internal ports (issue #83) ==="
echo ""

echo "Test 1: parser exposes container ID and target port when the port is not published"
reset_docker_stub
parsed="$(_parse_service_json '{"Service":"web","Image":"example/web","ID":"web-container","Publishers":[{"URL":"","TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}')"
assert_contains "parser keeps service name" "web" "$parsed"
assert_contains "parser keeps image" "example/web" "$parsed"
assert_contains "parser exposes container id" "web-container" "$parsed"
assert_contains "parser exposes target port 80" "80" "$parsed"

echo ""
echo "Test 2: discover_services uses NDJSON TargetPort values for scanner URLs"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","Publishers":[{"URL":"","TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"api","Image":"example/api","ID":"api-id","Ports":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
run_discovery
assert_eq "compact service list uses internal ports" "web:80,api:8080" "$HOSTED_SERVICES"
assert_contains "web detail uses service name and internal port" "http://web:80 (" "$HOSTED_SERVICES_DETAIL"
assert_contains "api detail uses service name and internal port" "http://api:8080" "$HOSTED_SERVICES_DETAIL"
assert_contains "internal detail is labelled internal" "(internal" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "internal-only services are not described as unpublished" "no published port" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 3: host-published ports are secondary when target port differs"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"web","Image":"example/web","ID":"web-id","Publishers":[{"URL":"0.0.0.0","TargetPort":80,"PublishedPort":8080,"Protocol":"tcp"}]}'
run_discovery
assert_eq "compact service list prefers Docker-network port" "web:80" "$HOSTED_SERVICES"
assert_contains "detail points scanners at target port" "http://web:80 (" "$HOSTED_SERVICES_DETAIL"
assert_contains "detail preserves host-published port as metadata" "published host port 8080" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "detail does not point scanner at host-published port" "http://web:8080" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 4: discovery falls back to docker inspect ExposedPorts"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"worker","Image":"example/worker","ID":"worker-id","Publishers":[]}'
DOCKER_INSPECT_FORMAT_OUTPUT="$(cat <<'EOF_FORMAT'
9000/udp
9090/tcp
EOF_FORMAT
)"
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{"9000/udp":{},"9090/tcp":{}}}}]'
run_discovery
assert_eq "compact service list uses inspected TCP exposed port" "worker:9090" "$HOSTED_SERVICES"
assert_contains "detail uses inspected TCP port" "http://worker:9090" "$HOSTED_SERVICES_DETAIL"
assert_contains "inspect fallback is labelled internal" "(internal" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 5: discovery resolves container ID before inspect when Compose JSON omits it"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"api","Image":"example/api","Publishers":[]}'
DOCKER_PS_Q_OUTPUT='api-container'
DOCKER_INSPECT_FORMAT_OUTPUT='8080/tcp'
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{"8080/tcp":{}}}}]'
run_discovery
calls="$(docker_calls)"
assert_eq "compact service list uses inspected port after ID lookup" "api:8080" "$HOSTED_SERVICES"
assert_contains "service-specific ps -q resolves missing ID" "ps -q api" "$calls"
assert_contains "resolved container ID is inspected" "api-container" "$calls"

echo ""
echo "Test 6: inspect failures are non-fatal and leave an explicit no-port detail"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"job","Image":"example/job","ID":"job-id","Publishers":[]}'
DOCKER_INSPECT_RC=42
run_discovery
rc=$?
assert_zero_rc "discover_services tolerates inspect failure" "$rc"
assert_eq "compact service list falls back to none" "job:none" "$HOSTED_SERVICES"
assert_contains "detail uses discovered-port wording" "no discovered port" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 7: JSON array compose output still uses internal target ports"
reset_docker_stub
DOCKER_PS_JSON='[{"Service":"web","Image":"example/web","ID":"web-id","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]},{"Service":"api","Image":"example/api","ID":"api-id","Ports":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}]'
run_discovery
assert_eq "array output compact list uses internal ports" "web:80,api:8080" "$HOSTED_SERVICES"
assert_contains "array output has web internal URL" "http://web:80 (" "$HOSTED_SERVICES_DETAIL"
assert_contains "array output has api internal URL" "http://api:8080" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 8: published-only metadata remains a fallback when no internal port is known"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"admin","Image":"example/admin","ID":"admin-id","Publishers":[{"URL":"0.0.0.0","PublishedPort":9443,"Protocol":"tcp"}]}'
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{}}}]'
run_discovery
assert_eq "compact service list falls back to published port" "admin:9443" "$HOSTED_SERVICES"
assert_contains "detail points at published fallback port" "http://admin:9443" "$HOSTED_SERVICES_DETAIL"
assert_contains "detail labels published-only fallback" "(published, example/admin)" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 9: Ports[].PrivatePort is accepted as an internal port"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"legacy","Image":"example/legacy","ID":"legacy-id","Ports":[{"PrivatePort":5000,"PublishedPort":0,"Protocol":"tcp"}]}'
run_discovery
assert_eq "compact service list uses private port" "legacy:5000" "$HOSTED_SERVICES"
assert_contains "detail uses private port URL" "http://legacy:5000" "$HOSTED_SERVICES_DETAIL"
assert_contains "private port detail is labelled internal" "(internal" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 10: Compose UDP ports are ignored for HTTP scanner URLs"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"metrics","Image":"example/metrics","ID":"metrics-id","Publishers":[{"TargetPort":8125,"PublishedPort":8125,"Protocol":"udp"},{"TargetPort":9090,"PublishedPort":0,"Protocol":"tcp"}]}'
run_discovery
assert_eq "compact service list skips UDP and uses TCP target" "metrics:9090" "$HOSTED_SERVICES"
assert_contains "detail uses TCP target port" "http://metrics:9090" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "detail does not use UDP port" "http://metrics:8125" "$HOSTED_SERVICES_DETAIL"

echo ""
echo "Test 11: Compose health status is surfaced without probing"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","Health":"healthy","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"api","Image":"example/api","ID":"api-id","Status":"Up 5 seconds (unhealthy)","Publishers":[{"TargetPort":8000,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"worker","Image":"example/worker","ID":"worker-id","Health":"starting","Publishers":[{"TargetPort":9000,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
run_discovery
calls="$(docker_calls)"
assert_contains "healthy healthcheck appears in details" "web: http://web:80 (internal, example/web) [healthy]" "$HOSTED_SERVICES_DETAIL"
assert_contains "unhealthy healthcheck appears in details" "api: http://api:8000 (internal, example/api) [unhealthy]" "$HOSTED_SERVICES_DETAIL"
assert_contains "starting healthcheck appears in details" "worker: http://worker:9000 (internal, example/worker) [starting]" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "explicit health statuses skip curl probe" "run --rm --network" "$calls"

echo ""
echo "Test 12: unknown health services are probed and 2xx/4xx responses count as responding"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","State":"running","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"admin","Image":"example/admin","ID":"admin-id","Status":"running","Publishers":[{"TargetPort":9443,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
set_docker_run_response "web" "80" "200" "0"
set_docker_run_response "admin" "9443" "404" "0"
run_discovery
calls="$(docker_calls)"
assert_contains "probe uses compose network" "run --rm --network issue83_default" "$calls"
assert_contains "HTTP 200 probe appears healthy" "web: http://web:80 (internal, example/web) [healthy]" "$HOSTED_SERVICES_DETAIL"
assert_contains "HTTP 404 probe appears responding, not unhealthy" "admin: http://admin:9443 (internal, example/admin) [responding HTTP 404]" "$HOSTED_SERVICES_DETAIL"
assert_eq "responding probes do not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 13: all unhealthy or unreachable HTTP services trigger a pre-scan warning"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"api","Image":"example/api","ID":"api-id","State":"running","Publishers":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"down","Image":"example/down","ID":"down-id","State":"running","Publishers":[{"TargetPort":8081,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
set_docker_run_response "api" "8080" "503" "0"
set_docker_run_response "down" "8081" "000" "7"
run_discovery
assert_contains "HTTP 503 probe appears unhealthy" "api: http://api:8080 (internal, example/api) [unhealthy HTTP 503]" "$HOSTED_SERVICES_DETAIL"
assert_contains "nonzero curl probe appears unreachable" "down: http://down:8081 (internal, example/down) [unreachable]" "$HOSTED_SERVICES_DETAIL"
assert_contains "all-unhealthy case warns before scanning" "All discovered hosted HTTP services are unhealthy or unreachable" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 14: mixed responding and unhealthy services do not warn"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","Health":"healthy","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"api","Image":"example/api","ID":"api-id","State":"running","Publishers":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
set_docker_run_response "api" "8080" "503" "0"
run_discovery
assert_contains "mixed case keeps healthy service status" "web: http://web:80 (internal, example/web) [healthy]" "$HOSTED_SERVICES_DETAIL"
assert_contains "mixed case keeps unhealthy service status" "api: http://api:8080 (internal, example/api) [unhealthy HTTP 503]" "$HOSTED_SERVICES_DETAIL"
assert_eq "mixed case does not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 15: missing hosted network produces unknown health and does not run curl"
reset_docker_stub
# shellcheck disable=SC2034  # Read by sourced hosted helpers during discovery.
HOSTED_NETWORK=""
DOCKER_PS_JSON='{"Service":"web","Image":"example/web","ID":"web-id","State":"running","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}'
run_discovery
calls="$(docker_calls)"
assert_contains "missing network appears as unknown health" "web: http://web:80 (internal, example/web) [unknown]" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "missing network skips curl probe" "run --rm --network" "$calls"
assert_eq "unknown probe state does not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 16: services without HTTP ports are not probed or counted"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"job","Image":"example/job","ID":"job-id","Publishers":[]}'
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{}}}]'
run_discovery
calls="$(docker_calls)"
assert_contains "no-port service gets not-probed status" "job: no discovered port (example/job) [not probed]" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "no-port service is not probed" "run --rm --network" "$calls"
assert_eq "no-port service does not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 17: object health and exited statuses are normalized without probing"
reset_docker_stub
DOCKER_PS_JSON="$(cat <<'JSON'
{"Service":"web","Image":"example/web","ID":"web-id","Health":{"Status":"healthy"},"Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
{"Service":"api","Image":"example/api","ID":"api-id","State":"exited","Publishers":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}
JSON
)"
run_discovery
calls="$(docker_calls)"
assert_contains "object health status appears healthy" "web: http://web:80 (internal, example/web) [healthy]" "$HOSTED_SERVICES_DETAIL"
assert_contains "exited state appears unhealthy" "api: http://api:8080 (internal, example/api) [unhealthy]" "$HOSTED_SERVICES_DETAIL"
assert_not_contains "object and exited statuses skip curl probe" "run --rm --network" "$calls"
assert_eq "healthy service prevents all-unhealthy warning" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 18: published-only services are probed on the published fallback port"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"admin","Image":"example/admin","ID":"admin-id","State":"running","Publishers":[{"URL":"0.0.0.0","PublishedPort":9443,"Protocol":"tcp"}]}'
DOCKER_INSPECT_JSON_OUTPUT='[{"Config":{"ExposedPorts":{}}}]'
set_docker_run_response "admin" "9443" "302" "0"
run_discovery
calls="$(docker_calls)"
assert_contains "published-only probe targets published port" "http://admin:9443/" "$calls"
assert_contains "HTTP 302 probe appears healthy" "admin: http://admin:9443 (published, example/admin) [healthy]" "$HOSTED_SERVICES_DETAIL"
assert_eq "3xx published fallback does not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 19: unparseable successful probes remain unknown and do not warn"
reset_docker_stub
DOCKER_PS_JSON='{"Service":"api","Image":"example/api","ID":"api-id","State":"running","Publishers":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}'
set_docker_run_response "api" "8080" "curl output without status" "0"
run_discovery
assert_contains "malformed probe output appears unknown" "api: http://api:8080 (internal, example/api) [unknown]" "$HOSTED_SERVICES_DETAIL"
assert_eq "unknown successful probe does not warn" "" "$LOG_WARN_MESSAGES"

echo ""
echo "Test 20: hosted API spec detection renders scanner-reachable OpenAPI URLs"
reset_docker_stub
HOSTED_NETWORK="issue85_default"
HOSTED_SERVICES="api:8080"
HOSTED_SERVICES_DETAIL="    - api: http://api:8080 (internal, example/api) [responding HTTP 404]"
set_docker_run_response_for_path "api" "8080" "/openapi.json" $'{"openapi":"3.0.3","info":{"title":"API","version":"1.0.0"},"paths":{}}\n200' "0"
probe_api_specs 2>/dev/null
rc=$?
hosted_section="$(build_hosted_section)"
assert_zero_rc "probe_api_specs succeeds when OpenAPI JSON is found" "$rc"
assert_contains "hosted section includes detected API specs block" "**Detected API specs:**" "$hosted_section"
assert_contains "detected spec uses service DNS name and selected port" "api: http://api:8080/openapi.json" "$hosted_section"
assert_contains "detected spec is labelled OpenAPI" "OpenAPI" "$hosted_section"

echo ""
echo "Test 21: raw Swagger/OpenAPI specs are preferred over 200 HTML pages"
reset_docker_stub
HOSTED_NETWORK="issue85_default"
HOSTED_SERVICES="api:8080"
HOSTED_SERVICES_DETAIL="    - api: http://api:8080 (internal, example/api) [healthy]"
set_docker_run_response_for_path "api" "8080" "/openapi.json" $'<html>not a machine-readable schema</html>\n200' "0"
set_docker_run_response_for_path "api" "8080" "/swagger.json" $'{"swagger":"2.0","info":{"title":"API","version":"1.0.0"},"paths":{}}\n200' "0"
set_docker_run_response_for_path "api" "8080" "/docs" $'<html><title>Swagger UI</title></html>\n200' "0"
probe_api_specs 2>/dev/null
rc=$?
hosted_section="$(build_hosted_section)"
assert_zero_rc "probe_api_specs succeeds after ignoring non-schema 200 content" "$rc"
assert_contains "first valid raw Swagger schema is surfaced" "api: http://api:8080/swagger.json" "$hosted_section"
assert_not_contains "200 HTML at schema path is not treated as the detected raw spec" "api: http://api:8080/openapi.json" "$hosted_section"
assert_not_contains "later docs UI does not replace an earlier raw spec" "api: http://api:8080/docs" "$hosted_section"

echo ""
echo "Test 22: api/v1 OpenAPI JSON is detected after earlier candidates miss"
reset_docker_stub
HOSTED_NETWORK="issue85_default"
HOSTED_SERVICES="api:8080"
HOSTED_SERVICES_DETAIL="    - api: http://api:8080 (internal, example/api) [healthy]"
set_docker_run_response_for_path "api" "8080" "/openapi.json" $'<html>not a machine-readable schema</html>\n200' "0"
set_docker_run_response_for_path "api" "8080" "/swagger.json" "500" "0"
set_docker_run_response_for_path "api" "8080" "/docs/openapi.json" $'{"message":"not a schema"}\n200' "0"
set_docker_run_response_for_path "api" "8080" "/api/v1/openapi.json" $'{"openapi":"3.0.3","info":{"title":"API","version":"1.0.0"},"paths":{}}\n200' "0"
probe_api_specs 2>/dev/null
rc=$?
hosted_section="$(build_hosted_section)"
assert_zero_rc "probe_api_specs succeeds when api/v1 schema is found" "$rc"
assert_contains "api/v1 OpenAPI schema is surfaced" "api: http://api:8080/api/v1/openapi.json (OpenAPI JSON)" "$hosted_section"

echo ""
echo "Test 23: docs endpoints are surfaced only as unconfirmed docs UI"
reset_docker_stub
HOSTED_NETWORK="issue85_default"
HOSTED_SERVICES="gateway:8000"
HOSTED_SERVICES_DETAIL="    - gateway: http://gateway:8000 (internal, example/gateway) [healthy]"
set_docker_run_response_for_path "gateway" "8000" "/api/docs" $'<html><title>Swagger UI</title></html>\n200' "0"
probe_api_specs 2>/dev/null
rc=$?
hosted_section="$(build_hosted_section)"
assert_zero_rc "probe_api_specs succeeds when only docs UI is found" "$rc"
assert_contains "docs UI endpoint is still made visible" "gateway: http://gateway:8000/api/docs" "$hosted_section"
assert_contains "docs UI label warns that raw schema is not confirmed" "schema URL not confirmed" "$hosted_section"

echo ""
echo "Test 24: non-200 responses, curl failures, and none ports do not produce spec entries"
reset_docker_stub
HOSTED_NETWORK="issue85_default"
HOSTED_SERVICES="api:8080,job:none"
HOSTED_SERVICES_DETAIL=$'    - api: http://api:8080 (internal, example/api) [healthy]\n    - job: no discovered port (example/job) [not probed]'
set_docker_run_response_for_path "api" "8080" "/openapi.json" "404" "0"
probe_api_specs 2>/dev/null
rc=$?
hosted_section="$(build_hosted_section)"
calls="$(docker_calls)"
assert_zero_rc "probe_api_specs succeeds when candidates fail" "$rc"
assert_not_contains "no detected block appears when all candidate probes fail" "**Detected API specs:**" "$hosted_section"
assert_not_contains "service:none entries are not probed" "http://job:none" "$calls"

echo ""
echo "Test 25: oversized API spec candidates are rejected"
reset_docker_stub
HOSTED_NETWORK="issue85_default"
HOSTED_SERVICES="api:8080"
HOSTED_SERVICES_DETAIL="    - api: http://api:8080 (internal, example/api) [healthy]"
# shellcheck disable=SC2034  # Read by sourced hosted helpers when probing response size.
HOSTED_API_SPEC_MAX_BODY_BYTES=32
set_docker_run_response_for_path "api" "8080" "/openapi.json" $'{"openapi":"3.0.3","padding":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}\n200' "0"
probe_api_specs 2>/dev/null
rc=$?
hosted_section="$(build_hosted_section)"
assert_zero_rc "probe_api_specs succeeds when oversized candidates are ignored" "$rc"
assert_not_contains "oversized 200 response does not produce detected specs block" "**Detected API specs:**" "$hosted_section"
assert_not_contains "oversized 200 response is not classified as OpenAPI" "api: http://api:8080/openapi.json" "$hosted_section"

echo ""
echo "Test 26: missing hosted network skips API spec probing"
reset_docker_stub
HOSTED_NETWORK=""
HOSTED_SERVICES="api:8080"
HOSTED_SERVICES_DETAIL="    - api: http://api:8080 (internal, example/api) [unknown]"
HOSTED_API_SPECS_DETAIL="    - stale: http://stale:8080/openapi.json (OpenAPI JSON)"
set_docker_run_response_for_path "api" "8080" "/openapi.json" $'{"openapi":"3.0.3","info":{"title":"API","version":"1.0.0"},"paths":{}}\n200' "0"
probe_api_specs 2>/dev/null
rc=$?
hosted_section="$(build_hosted_section)"
calls="$(docker_calls)"
assert_zero_rc "probe_api_specs succeeds as a no-op without a network" "$rc"
assert_eq "missing network clears stale detected API specs" "" "$HOSTED_API_SPECS_DETAIL"
assert_not_contains "missing network does not launch curl containers" "run --rm --network" "$calls"
assert_not_contains "missing network leaves detected specs block empty" "**Detected API specs:**" "$hosted_section"

echo ""
echo "Test 27: hosted API spec state is cleared between discovery and cleanup runs"
reset_docker_stub
HOSTED_API_SPECS_DETAIL="    - stale: http://stale:8080/openapi.json (OpenAPI)"
DOCKER_PS_JSON=""
run_discovery
assert_eq "discover_services clears stale detected API specs" "" "$HOSTED_API_SPECS_DETAIL"
HOSTED_API_SPECS_DETAIL="    - stale: http://stale:8080/openapi.json (OpenAPI)"
# shellcheck disable=SC2034  # Read by cleanup_hosted from sourced hosted helpers.
HOSTED_OWNER="false"
cleanup_hosted "issue85"
assert_eq "cleanup_hosted clears detected API specs" "" "$HOSTED_API_SPECS_DETAIL"

echo ""
echo "Test 28: YAML API specs are detected for multiple services"
reset_docker_stub
HOSTED_NETWORK="issue85_default"
HOSTED_SERVICES="api:8080,gateway:9090"
HOSTED_SERVICES_DETAIL=$'    - api: http://api:8080 (internal, example/api) [healthy]\n    - gateway: http://gateway:9090 (internal, example/gateway) [healthy]'
set_docker_run_response_for_path "api" "8080" "/openapi.yaml" $'openapi: 3.0.3\ninfo:\n  title: API\n  version: 1.0.0\npaths: {}\n200' "0"
set_docker_run_response_for_path "gateway" "9090" "/swagger.yml" $'swagger: "2.0"\ninfo:\n  title: Gateway\n  version: 1.0.0\npaths: {}\n200' "0"
probe_api_specs 2>/dev/null
rc=$?
hosted_section="$(build_hosted_section)"
assert_zero_rc "probe_api_specs succeeds when YAML schemas are found" "$rc"
assert_contains "OpenAPI YAML schema is surfaced" "api: http://api:8080/openapi.yaml (OpenAPI YAML)" "$hosted_section"
assert_contains "Swagger YAML schema is surfaced" "gateway: http://gateway:9090/swagger.yml (Swagger YAML)" "$hosted_section"

echo ""
echo "Test 29: setup_hosted_env probes API specs after service discovery"
reset_docker_stub
printf 'services: {}\n' > "$TMPDIR/docker-compose.yml"
# shellcheck disable=SC2034  # Read by setup_hosted_env before it discovers the network.
HOSTED_NETWORK=""
DOCKER_PS_JSON='{"Service":"api","Image":"example/api","ID":"api-id","Project":"issue85","State":"running","Publishers":[{"TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}'
DOCKER_PS_Q_OUTPUT="api-id"
DOCKER_INSPECT_FORMAT_OUTPUT="issue85_default"
set_docker_run_response "api" "8080" "404" "0"
set_docker_run_response_for_path "api" "8080" "/openapi.json" $'{"openapi":"3.1.0","info":{"title":"API","version":"1.0.0"},"paths":{}}\n200' "0"
setup_hosted_env "$TMPDIR" "issue85" 2>/dev/null
rc=$?
hosted_section="$(build_hosted_section)"
assert_zero_rc "setup_hosted_env succeeds with stubbed running compose service" "$rc"
assert_contains "setup_hosted_env discovered the scanner-reachable service" "api:8080" "$HOSTED_SERVICES"
assert_contains "setup_hosted_env renders detected specs from probe_api_specs" "api: http://api:8080/openapi.json (OpenAPI JSON)" "$hosted_section"

echo ""
echo "Test 30: later raw API schemas replace earlier docs UI candidates"
reset_docker_stub
# shellcheck disable=SC2034  # Read by sourced hosted helpers during API spec probing.
HOSTED_NETWORK="issue85_default"
HOSTED_SERVICES="gateway:9090"
HOSTED_SERVICES_DETAIL="    - gateway: http://gateway:9090 (internal, example/gateway) [healthy]"
set_docker_run_response_for_path "gateway" "9090" "/api-docs" $'<html><title>Swagger UI</title></html>\n200' "0"
set_docker_run_response_for_path "gateway" "9090" "/v3/api-docs" $'{"openapi":"3.0.3","info":{"title":"Gateway","version":"1.0.0"},"paths":{}}\n200' "0"
probe_api_specs 2>/dev/null
rc=$?
hosted_section="$(build_hosted_section)"
assert_zero_rc "probe_api_specs succeeds when raw schema follows docs UI" "$rc"
assert_contains "later raw schema is surfaced instead of the docs candidate" "gateway: http://gateway:9090/v3/api-docs (OpenAPI JSON)" "$hosted_section"
assert_not_contains "earlier docs UI candidate is not emitted when raw schema is found" "gateway: http://gateway:9090/api-docs" "$hosted_section"

echo ""
echo "=========================================="
echo "Results: $PASS/$TOTAL passed ($FAIL failed)"
echo "=========================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
