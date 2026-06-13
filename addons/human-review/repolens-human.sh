#!/usr/bin/env bash
# RepoLens human-review add-on.
#
# This script intentionally orchestrates the upstream RepoLens CLI from the
# outside instead of changing the core run loop. A parent run owns a lens queue;
# each `next` invocation executes exactly one child RepoLens focus run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REPOLENS_BIN="${REPOLENS_HUMAN_REPOLENS:-$REPO_ROOT/repolens.sh}"
HUMAN_LOG_ROOT="${REPOLENS_HUMAN_LOG_ROOT:-$REPO_ROOT/logs/human-review}"
CREATED_PARENT_RUN_ID=""
START_AT_INDEX=1
START_EXECUTION_MODE="agent"
declare -a START_REPOLENS_ARGS=()
declare -a START_DRY_RUN_ARGS=()

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/template.sh"

usage() {
  cat <<'USAGE'
Usage:
  addons/human-review/repolens-human.sh start [--start-at <lens-number>] <repolens args...>
  addons/human-review/repolens-human.sh next <parent-run-id>
  addons/human-review/repolens-human.sh complete <parent-run-id>
  addons/human-review/repolens-human.sh status <parent-run-id>

Examples:
  addons/human-review/repolens-human.sh start --project ~/app --agent codex --local --yes --domain security
  addons/human-review/repolens-human.sh start --project ~/app --agent current-session --local --yes
  addons/human-review/repolens-human.sh start --start-at 56 --project ~/app --agent codex --local --yes
  addons/human-review/repolens-human.sh next 20260612T120000Z-a1b2c3d4

Environment:
  REPOLENS_HUMAN_REPOLENS              Override path to repolens.sh.
  REPOLENS_HUMAN_LOG_ROOT             Override parent-run log root.
  REPOLENS_HUMAN_RATE_LIMIT_MAX_SLEEP Child RepoLens rate-limit sleep cap; default 0.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

prepend_path_dir() {
  local dir="$1" part new_path=""
  [[ -n "$dir" && -d "$dir" ]] || return 0

  IFS=':' read -r -a path_parts <<< "${PATH:-}"
  for part in "${path_parts[@]}"; do
    [[ -z "$part" || "$part" == "$dir" ]] && continue
    if [[ -z "$new_path" ]]; then
      new_path="$part"
    else
      new_path="$new_path:$part"
    fi
  done

  PATH="$dir${new_path:+:$new_path}"
}

prefer_user_tool_paths() {
  [[ -n "${HOME:-}" ]] || return 0
  prepend_path_dir "$HOME/bin"
  prepend_path_dir "$HOME/.local/bin"
  export PATH
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

new_parent_run_id() {
  local suffix
  suffix="$(od -An -tx1 -N4 /dev/urandom 2>/dev/null | tr -d ' \n')"
  if [[ -z "$suffix" ]]; then
    suffix="$$"
  fi
  printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$suffix"
}

json_array_from_args() {
  printf '%s\n' "$@" | jq -R -s 'split("\n")[:-1]'
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required for the human-review add-on"
}

parent_dir_for() {
  local parent_run_id="$1"
  [[ "$parent_run_id" != *"/"* && "$parent_run_id" != "." && "$parent_run_id" != ".." ]] \
    || die "Invalid parent run id: $parent_run_id"
  printf '%s/%s\n' "$HUMAN_LOG_ROOT" "$parent_run_id"
}

queue_file_for() {
  printf '%s/queue.json\n' "$1"
}

attempts_file_for() {
  printf '%s/attempts.json\n' "$1"
}

metadata_file_for() {
  printf '%s/metadata.json\n' "$1"
}

latest_file_for() {
  printf '%s/latest-result.json\n' "$1"
}

reject_unsupported_start_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run)
        die "Do not pass --dry-run to the add-on; start uses RepoLens dry-run internally"
        ;;
      --resume)
        die "Do not pass RepoLens --resume to the add-on; use 'next <parent-run-id>'"
        ;;
    esac
  done
}

parse_start_args() {
  START_AT_INDEX=1
  START_EXECUTION_MODE="agent"
  START_REPOLENS_ARGS=()
  START_DRY_RUN_ARGS=()

  while (($#)); do
    case "$1" in
      --start-at)
        [[ $# -ge 2 ]] || die "Option --start-at requires a 1-based lens number."
        START_AT_INDEX="$2"
        shift 2
        ;;
      --start-at=*)
        START_AT_INDEX="${1#*=}"
        shift
        ;;
      --agent)
        [[ $# -ge 2 ]] || die "Option --agent requires a value."
        START_REPOLENS_ARGS+=("$1" "$2")
        if [[ "$2" == "current-session" ]]; then
          START_EXECUTION_MODE="current-session"
          START_DRY_RUN_ARGS+=("$1" "codex")
        else
          START_DRY_RUN_ARGS+=("$1" "$2")
        fi
        shift 2
        ;;
      --agent=current-session)
        START_EXECUTION_MODE="current-session"
        START_REPOLENS_ARGS+=("$1")
        START_DRY_RUN_ARGS+=("--agent=codex")
        shift
        ;;
      *)
        START_REPOLENS_ARGS+=("$1")
        START_DRY_RUN_ARGS+=("$1")
        shift
        ;;
    esac
  done

  [[ "$START_AT_INDEX" =~ ^[0-9]+$ ]] || die "Option --start-at must be a positive integer."
  (( START_AT_INDEX >= 1 )) || die "Option --start-at must be at least 1."
}

parse_dry_run_lenses() {
  local dry_run_file="$1" out_file="$2"
  awk '
    $0 == "Lenses that would run:" { in_list = 1; next }
    in_list && $0 == "" { exit }
    in_list {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^[^[:space:]]+\/[^[:space:]]+$/) {
        print line
      }
    }
  ' "$dry_run_file" > "$out_file"
}

write_latest_result() {
  local parent_dir="$1" parent_run_id="$2" queue_file attempts_file metadata_file latest_file updated_at tmp
  queue_file="$(queue_file_for "$parent_dir")"
  attempts_file="$(attempts_file_for "$parent_dir")"
  metadata_file="$(metadata_file_for "$parent_dir")"
  latest_file="$(latest_file_for "$parent_dir")"
  updated_at="$(utc_now)"
  tmp="${latest_file}.tmp.$$"

  jq -n \
    --arg parent_run_id "$parent_run_id" \
    --arg parent_dir "$parent_dir" \
    --arg queue_file "$queue_file" \
    --arg attempts_file "$attempts_file" \
    --arg updated_at "$updated_at" \
    --slurpfile queue "$queue_file" \
    --slurpfile attempts "$attempts_file" \
    --slurpfile metadata "$metadata_file" '
      ($queue[0] // []) as $q
      | ($attempts[0] // []) as $a
      | ($metadata[0] // {}) as $m
      | ($q | length) as $total
      | ($q | map(select(.status == "completed")) | length) as $completed
      | ($q | map(select(.status == "skipped")) | length) as $skipped
      | ($q | map(select(.status == "failed")) | length) as $failed
      | ($q | map(select(.status == "awaiting_current_session")) | .[0]) as $awaiting
      | ($q | map(select(.status == "rate_limited_retryable" or .status == "running")) | .[0]) as $retry
      | ($q | map(select(.status == "pending")) | .[0]) as $pending
      | (if $awaiting then "awaiting_current_session"
         elif $retry then "rate_limited"
         elif $failed > 0 then "failed"
         elif $total > 0 and ($completed + $skipped) == $total then "completed"
         elif ($completed + $skipped) > 0 then "partial"
         else "running"
         end) as $status
      | (if $awaiting then {
           type: "complete_current_session",
           lens: $awaiting.entry,
           task_file: ($awaiting.task_file // null),
           output_dir: ($awaiting.output_dir // null)
         }
         elif $retry then {type: "retry_same_lens", lens: $retry.entry}
         elif $pending then {type: "run_next_lens", lens: $pending.entry}
         else {type: "none"}
         end) as $next_action
      | {
          parent_run_id: $parent_run_id,
          status: $status,
          active_lens: ($next_action.lens // null),
          next_action: $next_action,
          parent_dir: $parent_dir,
          queue_file: $queue_file,
          attempts_file: $attempts_file,
          execution_mode: ($m.execution_mode // "agent"),
          completed_lenses: $completed,
          skipped_lenses: $skipped,
          total_lenses: $total,
          repolens_args: ($m.repolens_args // []),
          child_runs: ($a | map({
            attempt: .attempt,
            lens: .lens,
            status: .status,
            exit_code: .exit_code,
            child_run_id: .child_run_id,
          child_log_dir: .child_log_dir,
          task_file: (.task_file // null),
            output_dir: (.output_dir // null),
            result_file: (.result_file // null)
          })),
          updated_at: $updated_at
        }
    ' > "$tmp" && mv -f "$tmp" "$latest_file" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }

  mkdir -p "$HUMAN_LOG_ROOT" || return 1
  cp "$latest_file" "$HUMAN_LOG_ROOT/latest-result.json" 2>/dev/null || true
}

create_parent_run() {
  local parent_run_id parent_dir metadata_file queue_file attempts_file dry_run_file lenses_file
  local args_json dry_args_json started_at dry_rc lens_count

  parse_start_args "$@"
  reject_unsupported_start_args "${START_REPOLENS_ARGS[@]}"
  [[ ${#START_REPOLENS_ARGS[@]} -gt 0 ]] || die "start requires RepoLens arguments"
  [[ -f "$REPOLENS_BIN" ]] || die "RepoLens entry point is not a file: $REPOLENS_BIN"

  parent_run_id="$(new_parent_run_id)"
  CREATED_PARENT_RUN_ID="$parent_run_id"
  parent_dir="$(parent_dir_for "$parent_run_id")"
  metadata_file="$(metadata_file_for "$parent_dir")"
  queue_file="$(queue_file_for "$parent_dir")"
  attempts_file="$(attempts_file_for "$parent_dir")"
  dry_run_file="$parent_dir/dry-run.txt"
  lenses_file="$parent_dir/dry-run-lenses.txt"

  mkdir -p "$parent_dir/attempts" || die "Unable to create parent run directory: $parent_dir"

  bash "$REPOLENS_BIN" "${START_DRY_RUN_ARGS[@]}" --dry-run > "$dry_run_file" 2>&1
  dry_rc=$?
  if (( dry_rc != 0 )); then
    printf 'RepoLens dry-run failed; see %s\n' "$dry_run_file" >&2
    exit "$dry_rc"
  fi

  parse_dry_run_lenses "$dry_run_file" "$lenses_file"
  [[ -s "$lenses_file" ]] || die "RepoLens dry-run did not report any lenses"
  lens_count="$(wc -l < "$lenses_file" | tr -d '[:space:]')"
  (( START_AT_INDEX <= lens_count )) || die "Option --start-at $START_AT_INDEX is outside the resolved lens list ($lens_count lenses)."

  args_json="$(json_array_from_args "${START_REPOLENS_ARGS[@]}")"
  dry_args_json="$(json_array_from_args "${START_DRY_RUN_ARGS[@]}")"
  started_at="$(utc_now)"
  jq -n \
    --arg parent_run_id "$parent_run_id" \
    --arg created_at "$started_at" \
    --arg dry_run_file "$dry_run_file" \
    --arg execution_mode "$START_EXECUTION_MODE" \
    --argjson start_at "$START_AT_INDEX" \
    --argjson repolens_args "$args_json" \
    --argjson dry_run_args "$dry_args_json" \
    '{
      parent_run_id: $parent_run_id,
      created_at: $created_at,
      updated_at: $created_at,
      status: "running",
      dry_run_file: $dry_run_file,
      execution_mode: $execution_mode,
      start_at: $start_at,
      repolens_args: $repolens_args,
      dry_run_args: $dry_run_args
    }' > "$metadata_file" || die "Unable to write metadata"

  jq -Rn --argjson start_at "$START_AT_INDEX" '
    [inputs | select(length > 0)
      | capture("^(?<domain>[^/]+)/(?<lens>.+)$")
      | .entry = (.domain + "/" + .lens)
      | .status = (if input_line_number < $start_at then "skipped" else "pending" end)
      | .attempts = 0
      | .last_child_run_id = null
      | .completed_child_run_id = null
      | .last_exit_code = null
      | .last_started_at = null
      | .last_finished_at = null
    ]
  ' < "$lenses_file" > "$queue_file" || die "Unable to write queue"

  printf '[]\n' > "$attempts_file" || die "Unable to write attempts"
  write_latest_result "$parent_dir" "$parent_run_id" || die "Unable to write latest result"

  printf 'Parent run: %s\n' "$parent_run_id"
  printf 'Parent dir: %s\n' "$parent_dir"
}

load_repolens_args() {
  local metadata_file="$1"
  mapfile -t REPOLENS_ARGS < <(jq -r '.repolens_args[]' "$metadata_file")
}

select_queue_entry() {
  local queue_file="$1"
  jq -r '
    (
      to_entries
      | map(select(.value.status == "awaiting_current_session" or .value.status == "rate_limited_retryable" or .value.status == "running"))
      | .[0]
    ) // (
      to_entries
      | map(select(.value.status == "pending"))
      | .[0]
    )
    | if . == null then "" else "\(.key)\t\(.value.entry)\t\(.value.status)" end
  ' "$queue_file"
}

update_parent_metadata_status() {
  local metadata_file="$1" status="$2" updated_at tmp
  updated_at="$(utc_now)"
  tmp="${metadata_file}.tmp.$$"
  jq --arg status "$status" --arg updated_at "$updated_at" \
    '.status = $status | .updated_at = $updated_at' \
    "$metadata_file" > "$tmp" && mv -f "$tmp" "$metadata_file" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
}

mark_queue_running() {
  local queue_file="$1" idx="$2" started_at tmp
  started_at="$(utc_now)"
  tmp="${queue_file}.tmp.$$"
  jq --argjson idx "$idx" --arg started_at "$started_at" '
    .[$idx].status = "running"
    | .[$idx].attempts = ((.[$idx].attempts // 0) + 1)
    | .[$idx].last_started_at = $started_at
    | .[$idx].last_finished_at = null
    | .[$idx].last_exit_code = null
  ' "$queue_file" > "$tmp" && mv -f "$tmp" "$queue_file" || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
}

mark_queue_finished() {
  local queue_file="$1" idx="$2" status="$3" exit_code="$4" child_run_id="$5" tmp finished_at
  finished_at="$(utc_now)"
  tmp="${queue_file}.tmp.$$"
  jq \
    --argjson idx "$idx" \
    --arg status "$status" \
    --argjson exit_code "$exit_code" \
    --arg child_run_id "$child_run_id" \
    --arg finished_at "$finished_at" '
      .[$idx].status = $status
      | .[$idx].last_exit_code = $exit_code
      | .[$idx].last_child_run_id = (if $child_run_id == "" then null else $child_run_id end)
      | .[$idx].last_finished_at = $finished_at
      | if $status == "completed" then
          .[$idx].completed_child_run_id = (if $child_run_id == "" then null else $child_run_id end)
        else
          .
        end
    ' "$queue_file" > "$tmp" && mv -f "$tmp" "$queue_file" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
}

mark_queue_awaiting_current_session() {
  local queue_file="$1" idx="$2" task_file="$3" output_dir="$4" tmp started_at
  started_at="$(utc_now)"
  tmp="${queue_file}.tmp.$$"
  jq \
    --argjson idx "$idx" \
    --arg task_file "$task_file" \
    --arg output_dir "$output_dir" \
    --arg started_at "$started_at" '
      .[$idx].status = "awaiting_current_session"
      | .[$idx].attempts = ((.[$idx].attempts // 0) + 1)
      | .[$idx].task_file = $task_file
      | .[$idx].output_dir = $output_dir
      | .[$idx].last_started_at = $started_at
      | .[$idx].last_finished_at = null
      | .[$idx].last_exit_code = null
    ' "$queue_file" > "$tmp" && mv -f "$tmp" "$queue_file" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
}

append_attempt() {
  local attempts_file="$1" attempt_json="$2" tmp
  tmp="${attempts_file}.tmp.$$"
  jq --argjson attempt "$attempt_json" '. + [$attempt]' "$attempts_file" > "$tmp" \
    && mv -f "$tmp" "$attempts_file" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
}

attempt_count() {
  local attempts_file="$1"
  jq 'length' "$attempts_file"
}

write_current_session_result_artifact() {
  local output_dir="$1" entry="$2" task_file="$3" completed_at="$4"
  local domain lens result_file tmp finding_files_json finding_count status

  domain="${entry%%/*}"
  lens="${entry#*/}"
  mkdir -p "$output_dir" || return 1

  finding_files_json="$(
    find "$output_dir" -maxdepth 1 -type f -name '*.md' -exec basename {} \; \
      | sort \
      | jq -R -s 'split("\n")[:-1]'
  )" || return 1
  finding_count="$(jq 'length' <<< "$finding_files_json")" || return 1
  if (( finding_count == 0 )); then
    status="no_findings"
  else
    status="findings_present"
  fi

  result_file="$output_dir/result.json"
  tmp="${result_file}.tmp.$$"
  jq -n \
    --arg lens "$entry" \
    --arg domain "$domain" \
    --arg lens_id "$lens" \
    --arg status "$status" \
    --arg task_file "$task_file" \
    --arg output_dir "$output_dir" \
    --arg completed_at "$completed_at" \
    --argjson finding_files "$finding_files_json" \
    --argjson finding_count "$finding_count" \
    '{
      lens: $lens,
      domain: $domain,
      lens_id: $lens_id,
      status: $status,
      finding_count: $finding_count,
      finding_files: $finding_files,
      task_file: $task_file,
      output_dir: $output_dir,
      completed_at: $completed_at
    }' > "$tmp" && mv -f "$tmp" "$result_file" || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }

  printf '%s\n' "$result_file"
}

parse_child_run_id() {
  local output_file="$1" run_id
  run_id="$(sed -n -E 's/.*RepoLens run ([^[:space:]]+) starting.*/\1/p' "$output_file" | tail -1)"
  if [[ -z "$run_id" ]]; then
    run_id="$(sed -n -E 's/.*RepoLens run ([^[:space:]]+) complete.*/\1/p' "$output_file" | tail -1)"
  fi
  printf '%s\n' "$run_id"
}

metadata_arg_value() {
  local metadata_file="$1" key="$2"
  local -a args
  local i arg
  mapfile -t args < <(jq -r '.repolens_args[]' "$metadata_file")
  for ((i = 0; i < ${#args[@]}; i++)); do
    arg="${args[$i]}"
    if [[ "$arg" == "$key" && $((i + 1)) -lt ${#args[@]} ]]; then
      printf '%s\n' "${args[$((i + 1))]}"
      return 0
    fi
    if [[ "$arg" == "$key="* ]]; then
      printf '%s\n' "${arg#*=}"
      return 0
    fi
  done
  printf '\n'
}

bridge_var_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

dry_run_repo_slug() {
  local dry_run_file="$1" slug
  slug="$(sed -n -E 's/.*Project: .*\(([^()]*)\).*/\1/p' "$dry_run_file" | tail -1)"
  printf '%s\n' "$slug"
}

bridge_task_slug() {
  local value="$1"
  printf '%s\n' "$value" | tr '/[:upper:]' '-[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

render_current_session_prompt() {
  local metadata_file="$1" parent_dir="$2" entry="$3" task_file="$4" output_dir="$5"
  local domain lens mode project_path repo_slug repo_owner repo_name base_file lens_file
  local domain_name domain_color lens_name label_prefix lens_label vars prompt dry_run_file

  domain="${entry%%/*}"
  lens="${entry#*/}"
  mode="$(metadata_arg_value "$metadata_file" "--mode")"
  [[ -n "$mode" ]] || mode="audit"
  project_path="$(metadata_arg_value "$metadata_file" "--project")"
  dry_run_file="$(jq -r '.dry_run_file // empty' "$metadata_file")"
  repo_slug="$(dry_run_repo_slug "$dry_run_file")"
  if [[ "$repo_slug" == */* ]]; then
    repo_owner="${repo_slug%%/*}"
    repo_name="${repo_slug#*/}"
  else
    repo_owner="local"
    repo_name="$(basename "$project_path")"
    repo_slug="$repo_owner/$repo_name"
  fi

  base_file="$REPO_ROOT/prompts/_base/$mode.md"
  [[ -f "$base_file" ]] || base_file="$REPO_ROOT/prompts/_base/audit.md"
  lens_file="$REPO_ROOT/prompts/lenses/$domain/$lens.md"
  [[ -f "$lens_file" ]] || die "Missing lens prompt for current-session bridge: $lens_file"

  lens_name="$(read_frontmatter "$lens_file" "name")"
  domain_name="$(jq -r --arg d "$domain" '.domains[] | select(.id == $d) | .name // empty' "$REPO_ROOT/config/domains.json")"
  [[ -n "$domain_name" ]] || domain_name="$domain"
  domain_color="$(jq -r --arg d "$domain" '.[$d] // "ededed"' "$REPO_ROOT/config/label-colors.json")"

  case "$mode" in
    audit) label_prefix="audit" ;;
    feature) label_prefix="feature" ;;
    bugfix) label_prefix="bugfix" ;;
    bugreport) label_prefix="bugreport" ;;
    discover) label_prefix="discover" ;;
    deploy) label_prefix="deploy" ;;
    custom) label_prefix="change" ;;
    opensource) label_prefix="opensource" ;;
    content) label_prefix="content" ;;
    greenfield) label_prefix="greenfield" ;;
    polish) label_prefix="polish" ;;
    *) label_prefix="$mode" ;;
  esac
  lens_label="${label_prefix}:${domain}/${lens}"

  vars="PROJECT_PATH=$(bridge_var_escape "$project_path")"
  vars+="|DOMAIN=$(bridge_var_escape "$domain")"
  vars+="|DOMAIN_NAME=$(bridge_var_escape "$domain_name")"
  vars+="|DOMAIN_COLOR=$(bridge_var_escape "$domain_color")"
  vars+="|LENS_ID=$(bridge_var_escape "$lens")"
  vars+="|LENS_NAME=$(bridge_var_escape "$lens_name")"
  vars+="|LENS_LABEL=$(bridge_var_escape "$lens_label")"
  vars+="|MODE=$(bridge_var_escape "$mode")"
  vars+="|RUN_ID=$(bridge_var_escape "$(basename "$parent_dir")")"
  vars+="|MIN_SEVERITY=$(bridge_var_escape "$(metadata_arg_value "$metadata_file" "--min-severity")")"
  vars+="|REPO_NAME=$(bridge_var_escape "$repo_name")"
  vars+="|REPO_OWNER=$(bridge_var_escape "$repo_owner")"
  vars+="|FORGE_REPO_SLUG=$(bridge_var_escape "$repo_slug")"
  vars+="|FORGE_ISSUE_CREATE=Write a local markdown finding instead"
  vars+="|FORGE_LABEL_CREATE=No label creation in current-session bridge"
  vars+="|FORGE_ENHANCEMENT_LABEL_CREATE=No label creation in current-session bridge"
  vars+="|FORGE_ISSUE_LIST_OPEN=Check existing markdown files in the output directory"
  vars+="|FORGE_ISSUE_LIST_CLOSED=Not available in current-session bridge"

  prompt="$(compose_prompt "$base_file" "$lens_file" "$vars" "" "$mode" "$(metadata_arg_value "$metadata_file" "--max-issues")" "" "false" "true" "$output_dir")"

  {
    printf '# ACTIVE SESSION BRIDGE\n\n'
    printf 'This task is for the already-running Codex session in this chat. Do not start `codex exec`, `claude`, `opencode`, or any other agent CLI.\n\n'
    printf 'For project commands that depend on local tools, use `bash addons/dev-doctor/dev-doctor-run.sh repolens --project %s --agent current-session --local -- <command> ...` so the same preflight PATH is used everywhere. From Windows PowerShell, use `wsl.exe --%% --cd %s --exec bash addons/dev-doctor/dev-doctor-run.sh repolens --project %s --agent current-session --local -- <command> ...` for arguments containing characters such as `(`, `)`, or `|`.\n\n' "$project_path" "$REPO_ROOT" "$project_path"
    printf 'Work directly in the shared workspace. Write findings, if any, to the output directory below, then run:\n\n'
    printf '```bash\nbash addons/human-review/repolens-human.sh complete %s\n```\n\n' "$(basename "$parent_dir")"
    printf 'Parent run: `%s`\n\n' "$(basename "$parent_dir")"
    printf 'Lens: `%s`\n\n' "$entry"
    printf 'Output directory: `%s`\n\n' "$output_dir"
    printf -- '---\n\n'
    printf '%s\n' "$prompt"
  } > "$task_file"
}

run_current_session_next() {
  local parent_run_id="$1" parent_dir="$2" metadata_file="$3" queue_file="$4" attempts_file="$5" idx="$6" entry="$7" current_status="$8"
  local domain lens attempt_number task_label safe_entry task_dir task_file output_dir

  domain="${entry%%/*}"
  lens="${entry#*/}"

  if [[ "$current_status" == "awaiting_current_session" ]]; then
    task_file="$(jq -r --argjson idx "$idx" '.[$idx].task_file // empty' "$queue_file")"
    output_dir="$(jq -r --argjson idx "$idx" '.[$idx].output_dir // empty' "$queue_file")"
    printf 'Parent run: %s\n' "$parent_run_id"
    printf 'Current-session lens is already awaiting completion: %s\n' "$entry"
    printf 'Task file: %s\n' "$task_file"
    printf 'Output dir: %s\n' "$output_dir"
    printf 'Complete with: %s complete %s\n' "$0" "$parent_run_id"
    return 0
  fi

  attempt_number=$(( $(attempt_count "$attempts_file") + 1 ))
  task_label="$(printf 'task-%03d' "$attempt_number")"
  safe_entry="$(bridge_task_slug "$entry")"
  task_dir="$parent_dir/current-session/tasks/${task_label}-${safe_entry}"
  task_file="$task_dir/prompt.md"
  output_dir="$parent_dir/current-session/lens-outputs/$domain/$lens"

  mkdir -p "$task_dir" "$output_dir" || die "Unable to create current-session task directories"
  render_current_session_prompt "$metadata_file" "$parent_dir" "$entry" "$task_file" "$output_dir" \
    || die "Unable to render current-session task"

  mark_queue_awaiting_current_session "$queue_file" "$idx" "$task_file" "$output_dir" \
    || die "Unable to mark lens awaiting current session"
  update_parent_metadata_status "$metadata_file" "awaiting_current_session" || die "Unable to update metadata"
  write_latest_result "$parent_dir" "$parent_run_id" || die "Unable to write latest result"

  printf 'Parent run: %s\n' "$parent_run_id"
  printf 'Current-session lens: %s\n' "$entry"
  printf 'Task file: %s\n' "$task_file"
  printf 'Output dir: %s\n' "$output_dir"
  printf 'Complete with: %s complete %s\n' "$0" "$parent_run_id"
}

complete_current_session() {
  local parent_run_id="$1" parent_dir metadata_file queue_file attempts_file selection idx entry
  local domain lens task_file output_dir attempt_number attempt_label started_at finished_at attempt_json parent_status
  local result_file

  parent_dir="$(parent_dir_for "$parent_run_id")"
  metadata_file="$(metadata_file_for "$parent_dir")"
  queue_file="$(queue_file_for "$parent_dir")"
  attempts_file="$(attempts_file_for "$parent_dir")"

  [[ -f "$metadata_file" ]] || die "Unknown parent run: $parent_run_id"
  [[ -f "$queue_file" ]] || die "Missing queue for parent run: $parent_run_id"
  [[ -f "$attempts_file" ]] || die "Missing attempts file for parent run: $parent_run_id"

  if [[ "$(jq -r '.execution_mode // "agent"' "$metadata_file")" != "current-session" ]]; then
    die "Parent run is not a current-session bridge run: $parent_run_id"
  fi

  selection="$(jq -r '
    (to_entries | map(select(.value.status == "awaiting_current_session")) | .[0])
    | if . == null then "" else "\(.key)\t\(.value.entry)" end
  ' "$queue_file")"
  [[ -n "$selection" ]] || die "No current-session lens is awaiting completion for parent run: $parent_run_id"

  idx="${selection%%$'\t'*}"
  entry="${selection#*$'\t'}"
  domain="${entry%%/*}"
  lens="${entry#*/}"
  task_file="$(jq -r --argjson idx "$idx" '.[$idx].task_file // empty' "$queue_file")"
  output_dir="$(jq -r --argjson idx "$idx" '.[$idx].output_dir // empty' "$queue_file")"
  started_at="$(jq -r --argjson idx "$idx" '.[$idx].last_started_at // empty' "$queue_file")"
  finished_at="$(utc_now)"
  attempt_number=$(( $(attempt_count "$attempts_file") + 1 ))
  attempt_label="$(printf 'attempt-%03d' "$attempt_number")"
  result_file="$(write_current_session_result_artifact "$output_dir" "$entry" "$task_file" "$finished_at")" \
    || die "Unable to write current-session result artifact"

  mark_queue_finished "$queue_file" "$idx" "completed" 0 "" || die "Unable to mark current-session lens completed"

  attempt_json="$(jq -n \
    --argjson attempt "$attempt_number" \
    --arg attempt_label "$attempt_label" \
    --arg lens "$entry" \
    --arg domain "$domain" \
    --arg lens_id "$lens" \
    --arg status "completed" \
    --argjson exit_code 0 \
    --arg task_file "$task_file" \
    --arg output_dir "$output_dir" \
    --arg result_file "$result_file" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    '{
      attempt: $attempt,
      attempt_label: $attempt_label,
      lens: $lens,
      domain: $domain,
      lens_id: $lens_id,
      status: $status,
      exit_code: $exit_code,
      task_file: $task_file,
      output_dir: $output_dir,
      result_file: $result_file,
      child_run_id: null,
      child_log_dir: null,
      started_at: $started_at,
      finished_at: $finished_at,
      command: ["current-session"]
    }'
  )" || die "Unable to build current-session attempt record"
  append_attempt "$attempts_file" "$attempt_json" || die "Unable to append attempt"

  parent_status="partial"
  if [[ "$(jq '[.[] | select(.status == "pending" or .status == "awaiting_current_session" or .status == "running" or .status == "rate_limited_retryable")] | length' "$queue_file")" == "0" ]]; then
    parent_status="completed"
  fi
  update_parent_metadata_status "$metadata_file" "$parent_status" || die "Unable to update metadata"
  write_latest_result "$parent_dir" "$parent_run_id" || die "Unable to write latest result"

  printf 'Parent run: %s\n' "$parent_run_id"
  printf 'Lens completed: %s\n' "$entry"
  printf 'Output dir: %s\n' "$output_dir"
}

run_next() {
  local parent_run_id="$1" parent_dir metadata_file queue_file attempts_file latest_file selection idx entry
  local selection_rest current_status execution_mode
  local domain lens attempt_number attempt_label attempt_output started_at finished_at child_run_id child_log_dir
  local rc child_status queue_status command_json attempt_json parent_status rate_limit_sleep
  local -a cmd

  parent_dir="$(parent_dir_for "$parent_run_id")"
  metadata_file="$(metadata_file_for "$parent_dir")"
  queue_file="$(queue_file_for "$parent_dir")"
  attempts_file="$(attempts_file_for "$parent_dir")"
  latest_file="$(latest_file_for "$parent_dir")"

  [[ -f "$metadata_file" ]] || die "Unknown parent run: $parent_run_id"
  [[ -f "$queue_file" ]] || die "Missing queue for parent run: $parent_run_id"
  [[ -f "$attempts_file" ]] || die "Missing attempts file for parent run: $parent_run_id"
  [[ -f "$REPOLENS_BIN" ]] || die "RepoLens entry point is not a file: $REPOLENS_BIN"

  selection="$(select_queue_entry "$queue_file")"
  if [[ -z "$selection" ]]; then
    update_parent_metadata_status "$metadata_file" "completed" || die "Unable to update metadata"
    write_latest_result "$parent_dir" "$parent_run_id" || die "Unable to write latest result"
    printf 'Parent run: %s\n' "$parent_run_id"
    printf 'No pending lenses. Parent run complete.\n'
    return 0
  fi

  idx="${selection%%$'\t'*}"
  selection_rest="${selection#*$'\t'}"
  entry="${selection_rest%%$'\t'*}"
  current_status="${selection_rest#*$'\t'}"
  execution_mode="$(jq -r '.execution_mode // "agent"' "$metadata_file")"
  if [[ "$execution_mode" == "current-session" ]]; then
    run_current_session_next "$parent_run_id" "$parent_dir" "$metadata_file" "$queue_file" "$attempts_file" "$idx" "$entry" "$current_status"
    return $?
  fi

  domain="${entry%%/*}"
  lens="${entry#*/}"
  attempt_number=$(( $(attempt_count "$attempts_file") + 1 ))
  attempt_label="$(printf 'attempt-%03d' "$attempt_number")"
  attempt_output="$parent_dir/attempts/${attempt_label}.out"

  load_repolens_args "$metadata_file"
  cmd=(bash "$REPOLENS_BIN" "${REPOLENS_ARGS[@]}" --domain "$domain" --focus "$lens")
  command_json="$(json_array_from_args "${cmd[@]}")"

  mark_queue_running "$queue_file" "$idx" || die "Unable to mark lens running"
  update_parent_metadata_status "$metadata_file" "running" || die "Unable to update metadata"
  write_latest_result "$parent_dir" "$parent_run_id" || die "Unable to write latest result"

  started_at="$(utc_now)"
  printf 'Parent run: %s\n' "$parent_run_id"
  printf 'Running lens: %s\n' "$entry"
  printf 'Attempt: %s\n' "$attempt_label"

  rate_limit_sleep="${REPOLENS_HUMAN_RATE_LIMIT_MAX_SLEEP:-0}"
  REPOLENS_RATE_LIMIT_MAX_SLEEP="$rate_limit_sleep" "${cmd[@]}" > "$attempt_output" 2>&1
  rc=$?
  finished_at="$(utc_now)"

  child_run_id="$(parse_child_run_id "$attempt_output")"
  child_log_dir=""
  if [[ -n "$child_run_id" ]]; then
    child_log_dir="$REPO_ROOT/logs/$child_run_id"
  fi

  case "$rc" in
    0)
      child_status="completed"
      queue_status="completed"
      parent_status="partial"
      ;;
    3)
      child_status="rate_limited"
      queue_status="rate_limited_retryable"
      parent_status="rate_limited"
      ;;
    *)
      child_status="failed"
      queue_status="failed"
      parent_status="failed"
      ;;
  esac

  mark_queue_finished "$queue_file" "$idx" "$queue_status" "$rc" "$child_run_id" \
    || die "Unable to update queue"

  attempt_json="$(jq -n \
    --argjson attempt "$attempt_number" \
    --arg attempt_label "$attempt_label" \
    --arg lens "$entry" \
    --arg domain "$domain" \
    --arg lens_id "$lens" \
    --arg status "$child_status" \
    --argjson exit_code "$rc" \
    --arg child_run_id "$child_run_id" \
    --arg child_log_dir "$child_log_dir" \
    --arg output_file "$attempt_output" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --argjson command "$command_json" \
    '{
      attempt: $attempt,
      attempt_label: $attempt_label,
      lens: $lens,
      domain: $domain,
      lens_id: $lens_id,
      status: $status,
      exit_code: $exit_code,
      child_run_id: (if $child_run_id == "" then null else $child_run_id end),
      child_log_dir: (if $child_log_dir == "" then null else $child_log_dir end),
      output_file: $output_file,
      started_at: $started_at,
      finished_at: $finished_at,
      command: $command
    }'
  )" || die "Unable to build attempt record"
  append_attempt "$attempts_file" "$attempt_json" || die "Unable to append attempt"

  update_parent_metadata_status "$metadata_file" "$parent_status" || die "Unable to update metadata"
  write_latest_result "$parent_dir" "$parent_run_id" || die "Unable to write latest result"

  case "$child_status" in
    completed)
      printf 'Lens completed: %s\n' "$entry"
      ;;
    rate_limited)
      printf 'Lens rate-limited; retry the same lens with: %s next %s\n' "$0" "$parent_run_id"
      ;;
    failed)
      printf 'Lens failed with exit code %s; see %s\n' "$rc" "$attempt_output" >&2
      ;;
  esac

  return "$rc"
}

show_status() {
  local parent_run_id="$1" parent_dir latest_file
  parent_dir="$(parent_dir_for "$parent_run_id")"
  latest_file="$(latest_file_for "$parent_dir")"
  [[ -f "$latest_file" ]] || die "No latest-result.json for parent run: $parent_run_id"
  jq '.' "$latest_file"
}

main() {
  local command="${1:-}"
  prefer_user_tool_paths
  require_jq

  case "$command" in
    start)
      shift
      create_parent_run "$@"
      [[ -n "$CREATED_PARENT_RUN_ID" ]] || die "Unable to resolve created parent run"
      run_next "$CREATED_PARENT_RUN_ID"
      ;;
    next)
      shift
      [[ $# -eq 1 ]] || { usage >&2; exit 1; }
      run_next "$1"
      ;;
    complete)
      shift
      [[ $# -eq 1 ]] || { usage >&2; exit 1; }
      complete_current_session "$1"
      ;;
    status)
      shift
      [[ $# -eq 1 ]] || { usage >&2; exit 1; }
      show_status "$1"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
