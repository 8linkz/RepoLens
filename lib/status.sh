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

# RepoLens - aggregated run status snapshots

STATUS_INTERVAL_DEFAULT=10
STATUS_UPDATER_PID=""
STATUS_LENSES_FILE=""
# shellcheck disable=SC2034 # Shared with repolens.sh after this file is sourced.
REPOLENS_FINAL_STATE="finished"

status_log_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$1"
  else
    printf 'WARN: %s\n' "$1" >&2
  fi
}

resolve_status_interval() {
  local interval="${REPOLENS_STATUS_INTERVAL:-$STATUS_INTERVAL_DEFAULT}"

  if [[ ! "$interval" =~ ^[0-9]+$ ]]; then
    status_log_warn "Invalid REPOLENS_STATUS_INTERVAL='$interval'; using default ${STATUS_INTERVAL_DEFAULT}s for status.json refreshes."
    interval="$STATUS_INTERVAL_DEFAULT"
  else
    interval=$((10#$interval))
    if (( interval <= 0 )); then
      status_log_warn "Invalid REPOLENS_STATUS_INTERVAL='$interval'; using default ${STATUS_INTERVAL_DEFAULT}s for status.json refreshes."
      interval="$STATUS_INTERVAL_DEFAULT"
    fi
  fi

  printf '%s\n' "$interval"
}

write_status_snapshot() {
  local state="$1" run_id="$2" log_base="$3" heartbeat_dir="$4" completed_file="$5" summary_file="$6"
  local project="$7" repo="$8" mode="$9" agent="${10}" parallel="${11}" max_parallel="${12}" lenses_file="${13}"
  local status_file="$log_base/status.json"
  local tmp_file="${status_file}.tmp.${BASHPID}"
  local active_tmp completed_tmp lenses_tmp
  local now_iso now_epoch started_at issues_created
  local heartbeat_file

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  now_epoch="$(date -u +%s)"

  started_at=""
  if [[ -f "$summary_file" ]]; then
    started_at="$(jq -r '.started_at // empty' "$summary_file" 2>/dev/null || true)"
  fi
  if [[ -z "$started_at" ]]; then
    started_at="$now_iso"
  fi

  issues_created=0
  if [[ -f "$summary_file" ]]; then
    issues_created="$(jq -r '.totals.issues_created // 0' "$summary_file" 2>/dev/null || printf '0')"
  fi
  if [[ ! "$issues_created" =~ ^[0-9]+$ ]]; then
    issues_created=0
  else
    issues_created=$((10#$issues_created))
  fi

  if [[ "$parallel" != "true" && "$parallel" != "false" ]]; then
    parallel=false
  fi
  if [[ ! "$max_parallel" =~ ^[0-9]+$ ]]; then
    max_parallel=0
  else
    max_parallel=$((10#$max_parallel))
  fi

  active_tmp="$(mktemp "$log_base/.status.active.XXXXXX")" || return 1
  completed_tmp="$(mktemp "$log_base/.status.completed.XXXXXX")" || {
    rm -f "$active_tmp"
    return 1
  }
  lenses_tmp="$(mktemp "$log_base/.status.lenses.XXXXXX")" || {
    rm -f "$active_tmp" "$completed_tmp"
    return 1
  }

  : > "$active_tmp"
  if [[ -d "$heartbeat_dir" ]]; then
    for heartbeat_file in "$heartbeat_dir"/*.json; do
      [[ -f "$heartbeat_file" ]] || continue
      jq -c --argjson now_epoch "$now_epoch" '
        def number_value($fallback):
          if type == "number" then .
          elif type == "string" then (tonumber? // $fallback)
          else $fallback
          end;
        def age_from($now):
          if type == "string" then
            ($now - (try fromdateiso8601 catch $now) | floor) as $age
            | if $age < 0 then 0 else $age end
          else 0
          end;
        select((.domain | type) == "string" and (.lens_id | type) == "string")
        | {
            domain: .domain,
            lens_id: .lens_id,
            pid: ((.pid // 0) | number_value(0)),
            iteration: ((.iteration // 0) | number_value(0)),
            started_at: (.started_at // ""),
            last_heartbeat_at: (.last_heartbeat_at // ""),
            age_seconds: ((.started_at // "") | age_from($now_epoch)),
            heartbeat_age_seconds: ((.last_heartbeat_at // "") | age_from($now_epoch))
          }
      ' "$heartbeat_file" >> "$active_tmp" 2>/dev/null || true
    done
  fi

  if [[ -f "$completed_file" ]]; then
    grep -v '^[[:space:]]*$' "$completed_file" 2>/dev/null | sort -u > "$completed_tmp" || : > "$completed_tmp"
  else
    : > "$completed_tmp"
  fi

  if [[ -f "$lenses_file" ]]; then
    grep -v '^[[:space:]]*$' "$lenses_file" 2>/dev/null > "$lenses_tmp" || : > "$lenses_tmp"
  else
    : > "$lenses_tmp"
  fi

  jq -n \
    --arg run_id "$run_id" \
    --arg project "$project" \
    --arg repo "$repo" \
    --arg mode "$mode" \
    --arg agent "$agent" \
    --argjson parallel "$parallel" \
    --argjson max_parallel "$max_parallel" \
    --arg started_at "$started_at" \
    --arg updated_at "$now_iso" \
    --arg state "$state" \
    --argjson issues_created "$issues_created" \
    --slurpfile active_raw <(jq -s 'sort_by(.domain, .lens_id)' "$active_tmp" 2>/dev/null || printf '[]') \
    --rawfile completed_raw "$completed_tmp" \
    --rawfile lenses_raw "$lenses_tmp" \
    '
      def lines_array($text):
        $text
        | split("\n")
        | map(select(length > 0));

      ($active_raw[0] // []) as $active
      | (lines_array($lenses_raw)) as $lenses
      | (lines_array($completed_raw) | unique) as $completed_all
      | ($lenses | unique) as $lens_set
      | ($active | map(.domain + "/" + .lens_id) | unique) as $active_keys
      | ($completed_all | map(select(. as $item | $lens_set | index($item))) | unique) as $completed
      | ($lenses | map(select(. as $item | (($active_keys | index($item)) | not) and (($completed | index($item)) | not)))) as $queued
      | ($lenses | length) as $total
      | ($completed | length) as $completed_count
      | {
          run_id: $run_id,
          project: $project,
          repo: $repo,
          mode: $mode,
          agent: $agent,
          parallel: $parallel,
          max_parallel: $max_parallel,
          started_at: $started_at,
          updated_at: $updated_at,
          state: $state,
          total_lenses: $total,
          counts: {
            queued: ($queued | length),
            active: ($active | length),
            completed: $completed_count,
            issues_created: $issues_created
          },
          completion_percentage: (if $total == 0 then 0 else (($completed_count * 10000 / $total) | round / 100) end),
          active: $active,
          queued: $queued,
          completed: $completed
        }
    ' > "$tmp_file" && mv -f "$tmp_file" "$status_file"

  local rc=$?
  rm -f "$active_tmp" "$completed_tmp" "$lenses_tmp" "$tmp_file"
  return "$rc"
}

status_updater_loop() {
  local interval="$1"
  local parent_pid="$2"
  shift 2
  local sleep_pid=""

  trap '[[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null; exit 0' TERM INT

  while true; do
    if [[ "$parent_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$parent_pid" 2>/dev/null; then
      exit 0
    fi
    command -p sleep "$interval" &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null || exit 0
    sleep_pid=""
    if [[ "$parent_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$parent_pid" 2>/dev/null; then
      exit 0
    fi
    write_status_snapshot "running" "$@" || true
  done
}

start_status_updater() {
  local run_id="$1" log_base="$2" heartbeat_dir="$3" completed_file="$4" summary_file="$5"
  local project="$6" repo="$7" mode="$8" agent="$9" parallel="${10}" max_parallel="${11}"
  local interval

  STATUS_LENSES_FILE="$log_base/.status-lenses"
  printf '%s\n' "${LENS_LIST[@]}" > "$STATUS_LENSES_FILE"

  interval="$(resolve_status_interval)"
  write_status_snapshot "running" "$run_id" "$log_base" "$heartbeat_dir" "$completed_file" "$summary_file" "$project" "$repo" "$mode" "$agent" "$parallel" "$max_parallel" "$STATUS_LENSES_FILE" || true

  bash -c '
    source "$1"
    shift
    status_updater_loop "$@"
  ' "repolens-status-updater:$run_id" "$SCRIPT_DIR/lib/status.sh" \
    "$interval" "$$" "$run_id" "$log_base" "$heartbeat_dir" "$completed_file" "$summary_file" \
    "$project" "$repo" "$mode" "$agent" "$parallel" "$max_parallel" "$STATUS_LENSES_FILE" \
    >/dev/null 2>&1 &

  STATUS_UPDATER_PID="$!"
}

stop_status_updater() {
  local final_state="${1:-finished}"

  if [[ "${STATUS_UPDATER_PID:-}" =~ ^[0-9]+$ ]]; then
    if kill -0 "$STATUS_UPDATER_PID" 2>/dev/null; then
      kill "$STATUS_UPDATER_PID" 2>/dev/null || true
    fi
    wait "$STATUS_UPDATER_PID" 2>/dev/null || true
  fi
  STATUS_UPDATER_PID=""

  if [[ -n "${RUN_ID:-}" && -n "${LOG_BASE:-}" && -n "${HEARTBEAT_DIR:-}" && -n "${completed_lenses_file:-}" && -n "${SUMMARY_FILE:-}" && -n "${STATUS_LENSES_FILE:-}" ]]; then
    write_status_snapshot \
      "$final_state" "${RUN_ID:-}" "${LOG_BASE:-}" "${HEARTBEAT_DIR:-}" "${completed_lenses_file:-}" \
      "${SUMMARY_FILE:-}" "${PROJECT_PATH:-}" "${FORGE_REPO_SLUG:-}" "${MODE:-}" "${AGENT:-}" \
      "${PARALLEL:-}" "${MAX_PARALLEL:-}" "${STATUS_LENSES_FILE:-}" || true
  fi
}
