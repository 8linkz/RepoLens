#!/usr/bin/env bash
# Generic pre-start dependency checker for RepoLens-style projects.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/profiles"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_PROFILE_DIR="${DEV_DOCTOR_PROFILE_DIR:-$CONFIG_HOME/dev-doctor/profiles}"

PROFILE=""
PROJECT_PATH=""
AGENT=""
ALL_AGENTS=false
LOCAL_MODE=false
APPLY=false
JSON_OUTPUT=false
VERBOSE=false
INTERACTIVE_SUDO=false

usage() {
  cat <<'USAGE'
Usage:
  dev-doctor [profile-name] [--profile path] [--project path] [--agent name|all] [--all-agents] [--local] [--apply] [--json]

Examples:
  bash addons/dev-doctor/dev-doctor.sh repolens --agent codex --local
  bash addons/dev-doctor/dev-doctor.sh --profile .devdoctor.json --agent claude --local
  bash addons/dev-doctor/dev-doctor.sh repolens --agent codex --apply
  bash addons/dev-doctor/dev-doctor.sh repolens --all-agents --apply
  bash addons/dev-doctor/dev-doctor.sh repolens --install-agent codex --local

Options:
  --profile <path>  Read an explicit profile JSON file.
  --project <path>  Project/repository path used by project file checks.
  --agent <name>    Activate checks required for that agent. Use "all" for all agents.
  --all-agents      Activate every check that declares required_when.agent.
  --install-agent <name|all>
                    Convenience form for --agent/--all-agents plus --apply.
  --local           Skip checks only needed for remote forge filing.
  --apply           Install missing apt/npm packages when a profile declares them.
  --interactive-sudo
                    Allow sudo to prompt when stdin is a real terminal.
  --json            Emit machine-readable JSON instead of the human table.
  --verbose         Include skipped optional checks in human output.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

json_escape() {
  jq -Rn --arg v "$1" '$v'
}

parse_args() {
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --profile)
        [[ $# -ge 2 ]] || die "--profile requires a path"
        PROFILE="$2"
        shift 2
        ;;
      --agent)
        [[ $# -ge 2 ]] || die "--agent requires a value"
        AGENT="$2"
        if [[ "$AGENT" == "all" ]]; then
          ALL_AGENTS=true
        fi
        shift 2
        ;;
      --project)
        [[ $# -ge 2 ]] || die "--project requires a path"
        PROJECT_PATH="$2"
        shift 2
        ;;
      --all-agents)
        ALL_AGENTS=true
        AGENT="all"
        shift
        ;;
      --install-agent)
        [[ $# -ge 2 ]] || die "--install-agent requires a value"
        if [[ "$2" == "all" ]]; then
          ALL_AGENTS=true
          AGENT="all"
        else
          AGENT="$2"
        fi
        APPLY=true
        shift 2
        ;;
      --local)
        LOCAL_MODE=true
        shift
        ;;
      --apply)
        APPLY=true
        shift
        ;;
      --interactive-sudo)
        INTERACTIVE_SUDO=true
        shift
        ;;
      --json)
        JSON_OUTPUT=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      --*)
        die "Unknown option: $arg"
        ;;
      *)
        if [[ -z "$PROFILE" ]]; then
          PROFILE="$arg"
        else
          die "Unexpected argument: $arg"
        fi
        shift
        ;;
    esac
  done
}

resolve_project_path() {
  local project="$1"
  if [[ -z "$project" ]]; then
    project="."
  fi
  [[ -d "$project" ]] || die "Project path not found: $project"
  (cd "$project" && pwd -P)
}

resolve_profile() {
  local profile="$1"
  if [[ -z "$profile" ]]; then
    if [[ -f ".devdoctor.json" ]]; then
      printf '%s\n' ".devdoctor.json"
      return 0
    fi
    die "No profile supplied and .devdoctor.json was not found"
  fi

  if [[ -f "$profile" ]]; then
    printf '%s\n' "$profile"
    return 0
  fi

  if [[ -f "$PROFILE_DIR/$profile.json" ]]; then
    printf '%s\n' "$PROFILE_DIR/$profile.json"
    return 0
  fi

  if [[ -f "$CONFIG_PROFILE_DIR/$profile.json" ]]; then
    printf '%s\n' "$CONFIG_PROFILE_DIR/$profile.json"
    return 0
  fi

  die "Profile not found: $profile"
}

detect_package_manager() {
  if have_cmd apt-get; then
    printf 'apt\n'
  elif have_cmd brew; then
    printf 'brew\n'
  elif have_cmd winget.exe; then
    printf 'winget\n'
  else
    printf 'unknown\n'
  fi
}

run_privileged() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
    return $?
  fi

  if ! have_cmd sudo; then
    printf 'dev-doctor: sudo is required to run: %s\n' "$*" >&2
    return 1
  fi

  if sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
    return $?
  fi

  if [[ "$INTERACTIVE_SUDO" == "true" && -t 0 ]]; then
    sudo "$@"
    return $?
  fi

  printf 'dev-doctor: sudo password required; rerun this command in an interactive terminal or install manually: %s\n' "$*" >&2
  return 1
}

project_files_required() {
  local check_json="$1" count i rel
  count="$(jq '(.required_when.project_files // []) | length' <<< "$check_json")"
  if (( count == 0 )); then
    printf 'false\n'
    return 0
  fi

  for (( i = 0; i < count; i++ )); do
    rel="$(jq -r ".required_when.project_files[$i]" <<< "$check_json")"
    if [[ -e "$PROJECT_PATH/$rel" ]]; then
      printf 'true\n'
      return 0
    fi
  done

  printf 'false\n'
}

project_globs_required() {
  local check_json="$1" count i rel match globstar_was_on nullglob_was_on
  count="$(jq '(.required_when.project_globs // []) | length' <<< "$check_json")"
  if (( count == 0 )); then
    printf 'false\n'
    return 0
  fi

  shopt -q globstar
  globstar_was_on=$?
  shopt -q nullglob
  nullglob_was_on=$?
  shopt -s globstar nullglob

  for (( i = 0; i < count; i++ )); do
    rel="$(jq -r ".required_when.project_globs[$i]" <<< "$check_json")"
    for match in "$PROJECT_PATH"/$rel; do
      if [[ -e "$match" ]]; then
        (( globstar_was_on == 0 )) || shopt -u globstar
        (( nullglob_was_on == 0 )) || shopt -u nullglob
        printf 'true\n'
        return 0
      fi
    done
  done

  (( globstar_was_on == 0 )) || shopt -u globstar
  (( nullglob_was_on == 0 )) || shopt -u nullglob
  printf 'false\n'
}

check_required() {
  local check_json="$1" required agent_match not_local required_value agent_declared project_required project_glob_required
  required_value="$(jq -r '.required // false' <<< "$check_json")"
  if [[ "$required_value" == "true" ]]; then
    printf 'true\n'
    return 0
  fi

  project_required="$(project_files_required "$check_json")"
  if [[ "$project_required" == "true" ]]; then
    printf 'true\n'
    return 0
  fi

  project_glob_required="$(project_globs_required "$check_json")"
  if [[ "$project_glob_required" == "true" ]]; then
    printf 'true\n'
    return 0
  fi

  if [[ "$ALL_AGENTS" == "true" ]]; then
    agent_declared="$(jq -r '((.required_when.agent // []) | length) > 0' <<< "$check_json")"
    if [[ "$agent_declared" == "true" ]]; then
      printf 'true\n'
      return 0
    fi
  fi

  if [[ -n "$AGENT" && "$AGENT" != "all" ]]; then
    agent_match="$(jq -r --arg agent "$AGENT" '
      (.required_when.agent // [])
      | any(. as $pattern
        | if ($pattern | endswith("*")) then
            ($agent | startswith($pattern[0:-1]))
          else
            $agent == $pattern
          end
        )
    ' <<< "$check_json")"
    if [[ "$agent_match" == "true" ]]; then
      printf 'true\n'
      return 0
    fi
  fi

  not_local="$(jq -r '.required_when.not_local // false' <<< "$check_json")"
  if [[ "$not_local" == "true" && "$LOCAL_MODE" != "true" ]]; then
    printf 'true\n'
    return 0
  fi

  required="$(jq -r '.required_when.always // false' <<< "$check_json")"
  if [[ "$required" == "true" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

check_applies() {
  local check_json="$1" required optional_when
  required="$(check_required "$check_json")"
  if [[ "$required" == "true" ]]; then
    printf 'true\n'
    return 0
  fi

  optional_when="$(jq -r '.optional // false' <<< "$check_json")"
  if [[ "$optional_when" == "true" ]]; then
    printf 'optional\n'
  else
    printf 'false\n'
  fi
}

install_hint_for() {
  local check_json="$1" hint
  hint="$(jq -r '.install.hint // empty' <<< "$check_json")"
  if [[ -n "$hint" ]]; then
    printf '%s\n' "$hint"
    return 0
  fi

  case "$(detect_package_manager)" in
    apt)
      hint="$(jq -r '.install.apt // empty' <<< "$check_json")"
      [[ -n "$hint" ]] && printf 'sudo apt-get install -y %s\n' "$hint"
      ;;
    brew)
      hint="$(jq -r '.install.brew // empty' <<< "$check_json")"
      [[ -n "$hint" ]] && printf 'brew install %s\n' "$hint"
      ;;
    winget)
      hint="$(jq -r '.install.winget // empty' <<< "$check_json")"
      [[ -n "$hint" ]] && printf 'winget install %s\n' "$hint"
      ;;
  esac
}

effective_path_for_command() {
  local command_name="$1" current_path local_bin
  current_path="$(command -v "$command_name" 2>/dev/null || true)"
  local_bin="$HOME/.local/bin"
  case "$current_path" in
    /mnt/c/*|"")
      if [[ -x "$local_bin/$command_name" ]]; then
        printf '%s:%s\n' "$local_bin" "$PATH"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$PATH"
}

run_health_check() {
  local command_name="$1" health="$2" effective_path
  [[ -n "$health" ]] || return 0
  effective_path="$(effective_path_for_command "$command_name")"
  DEV_DOCTOR_DIR="$SCRIPT_DIR" DEV_DOCTOR_PROJECT="$PROJECT_PATH" PATH="$effective_path" bash -c "$health" >/dev/null 2>&1
}

resolve_command_path() {
  local command_name="$1" effective_path
  effective_path="$(effective_path_for_command "$command_name")"
  PATH="$effective_path" command -v "$command_name" 2>/dev/null || true
}

evaluate_check() {
  local check_json="$1" applies id command health status path hint required
  id="$(jq -r '.id' <<< "$check_json")"
  command="$(jq -r '.command // .id' <<< "$check_json")"
  health="$(jq -r '.health // empty' <<< "$check_json")"
  applies="$(check_applies "$check_json")"
  hint="$(install_hint_for "$check_json")"
  required="$(check_required "$check_json")"

  if [[ "$applies" == "false" ]]; then
    jq -n \
      --arg id "$id" \
      --arg command "$command" \
      --arg status "skipped" \
      --arg required "false" \
      --arg hint "$hint" \
      '{id:$id, command:$command, status:$status, required:($required == "true"), hint:$hint}'
    return 0
  fi

  path="$(resolve_command_path "$command")"
  if [[ -z "$path" ]]; then
    status="missing"
  elif ! run_health_check "$command" "$health"; then
    status="broken"
  else
    status="ok"
  fi

  jq -n \
    --arg id "$id" \
    --arg command "$command" \
    --arg status "$status" \
    --arg required "$required" \
    --arg path "$path" \
    --arg hint "$hint" \
    '{id:$id, command:$command, status:$status, required:($required == "true"), path:(if $path == "" then null else $path end), hint:$hint}'
}

apply_install_for_result() {
  local check_json="$1" result_json="$2" status apt_pkg npm_pkg shell_cmd
  status="$(jq -r '.status' <<< "$result_json")"
  case "$status" in
    missing|broken) ;;
    *) return 0 ;;
  esac

  apt_pkg="$(jq -r '.install.apt // empty' <<< "$check_json")"
  npm_pkg="$(jq -r '.install.npm_global // empty' <<< "$check_json")"
  shell_cmd="$(jq -r '.install.shell // empty' <<< "$check_json")"

  if [[ -n "$apt_pkg" && "$(detect_package_manager)" == "apt" ]]; then
    run_privileged apt-get update && run_privileged apt-get install -y $apt_pkg
    return $?
  fi

  if [[ -n "$shell_cmd" ]]; then
    DEV_DOCTOR_DIR="$SCRIPT_DIR" DEV_DOCTOR_PROJECT="$PROJECT_PATH" bash -lc "$shell_cmd"
    return $?
  fi

  if [[ -n "$npm_pkg" ]]; then
    if ! have_cmd node || ! node --version >/dev/null 2>&1; then
      printf 'dev-doctor: cannot install %s before node is available in this shell\n' "$npm_pkg" >&2
      return 1
    fi
    if ! have_cmd npm || ! npm --version >/dev/null 2>&1; then
      printf 'dev-doctor: cannot install %s before npm is available in this shell\n' "$npm_pkg" >&2
      return 1
    fi
    npm install -g "$npm_pkg"
    return $?
  fi

  return 0
}

print_human_result() {
  local result_json="$1" id status path hint required label
  id="$(jq -r '.id' <<< "$result_json")"
  status="$(jq -r '.status' <<< "$result_json")"
  path="$(jq -r '.path // empty' <<< "$result_json")"
  hint="$(jq -r '.hint // empty' <<< "$result_json")"
  required="$(jq -r '.required // false' <<< "$result_json")"

  if [[ "$status" == "skipped" && "$VERBOSE" != "true" ]]; then
    return 0
  fi

  case "$status" in
    ok) label="OK" ;;
    missing)
      if [[ "$required" == "true" ]]; then
        label="MISSING"
      else
        label="OPTION"
      fi
      ;;
    broken)
      if [[ "$required" == "true" ]]; then
        label="BROKEN"
      else
        label="WARN"
      fi
      ;;
    skipped) label="SKIP" ;;
    *) label="$status" ;;
  esac

  if [[ -n "$path" ]]; then
    printf '%-7s %-16s %s\n' "$label" "$id" "$path"
  else
    printf '%-7s %s\n' "$label" "$id"
  fi

  if [[ "$required" == "true" && "$status" != "ok" && -n "$hint" ]]; then
    printf '        fix: %s\n' "$hint"
  fi
}

main() {
  local profile_path profile_name checks_count i check_json result_json results_file missing_count broken_count apply_failed=0

  parse_args "$@"
  have_cmd jq || die "jq is required to run dev-doctor itself"

  PROJECT_PATH="$(resolve_project_path "$PROJECT_PATH")"
  profile_path="$(resolve_profile "$PROFILE")"
  jq -e '.checks | type == "array"' "$profile_path" >/dev/null 2>&1 \
    || die "Invalid profile: .checks must be an array"
  profile_name="$(jq -r '.name // "unnamed"' "$profile_path")"

  results_file="$(mktemp)"
  printf '[]\n' > "$results_file"

  checks_count="$(jq '.checks | length' "$profile_path")"
  for (( i = 0; i < checks_count; i++ )); do
    check_json="$(jq -c ".checks[$i]" "$profile_path")"
    result_json="$(evaluate_check "$check_json")"

    if $APPLY; then
      if ! apply_install_for_result "$check_json" "$result_json"; then
        apply_failed=1
      fi
      result_json="$(evaluate_check "$check_json")"
    fi

    tmp_file="${results_file}.tmp.$$"
    jq --argjson item "$result_json" '. + [$item]' "$results_file" > "$tmp_file" \
      && mv -f "$tmp_file" "$results_file"
  done

  missing_count="$(jq '[.[] | select(.required == true and .status == "missing")] | length' "$results_file")"
  broken_count="$(jq '[.[] | select(.required == true and .status == "broken")] | length' "$results_file")"

  if $JSON_OUTPUT; then
    jq \
      --arg profile "$profile_name" \
      --arg profile_path "$profile_path" \
      --arg agent "$AGENT" \
      --argjson all_agents "$ALL_AGENTS" \
      --argjson local "$LOCAL_MODE" \
      --argjson apply_failed "$apply_failed" \
      --argjson missing "$missing_count" \
      --argjson broken "$broken_count" \
      '{
        profile: $profile,
        profile_path: $profile_path,
        agent: (if $agent == "" then null else $agent end),
        all_agents: $all_agents,
        local: $local,
        healthy: ($missing == 0 and $broken == 0 and ($apply_failed == 0)),
        missing_required: $missing,
        broken_required: $broken,
        apply_failed: $apply_failed,
        checks: .
      }' "$results_file"
  else
    printf 'dev-doctor profile: %s\n' "$profile_name"
    if [[ "$ALL_AGENTS" == "true" ]]; then
      printf 'agents: all\n'
    elif [[ -n "$AGENT" ]]; then
      printf 'agent: %s\n' "$AGENT"
    fi
    printf 'local mode: %s\n\n' "$LOCAL_MODE"
    jq -c '.[]' "$results_file" | while IFS= read -r result_json; do
      print_human_result "$result_json"
    done
    printf '\n'
    if (( missing_count == 0 && broken_count == 0 && apply_failed == 0 )); then
      printf 'dev-doctor: all required checks passed\n'
    else
      printf 'dev-doctor: %s missing, %s broken required checks\n' "$missing_count" "$broken_count"
    fi
  fi

  rm -f "$results_file" "${results_file}.tmp.$$" 2>/dev/null || true

  if (( apply_failed != 0 )); then
    return 3
  fi
  if (( missing_count != 0 || broken_count != 0 )); then
    return 2
  fi
  return 0
}

main "$@"
