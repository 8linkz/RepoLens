#!/usr/bin/env bash
# Run a command in the tool environment validated by dev-doctor.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_DOCTOR="${DEV_DOCTOR_BIN:-$SCRIPT_DIR/dev-doctor.sh}"

usage() {
  cat <<'USAGE'
Usage:
  dev-doctor-run [dev-doctor args...] -- <command> [args...]

Examples:
  bash addons/dev-doctor/dev-doctor-run.sh repolens --project ~/app --local -- go test ./...
  bash addons/dev-doctor/dev-doctor-run.sh repolens --project ~/app --agent current-session --local -- rg -n TODO

The command runs only after dev-doctor reports all required checks healthy.
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

main() {
  local -a doctor_args=() cmd=()
  local seen_separator=false result_file rc path dir run_cwd=""

  while (($#)); do
    if [[ "$1" == "--" ]]; then
      seen_separator=true
      shift
      break
    fi
    case "$1" in
      -h|--help|help)
        usage
        exit 0
        ;;
    esac
    case "$1" in
      --project)
        [[ $# -ge 2 ]] || die "--project requires a path"
        run_cwd="$2"
        doctor_args+=("$1" "$2")
        shift 2
        ;;
      *)
        doctor_args+=("$1")
        shift
        ;;
    esac
  done

  [[ "$seen_separator" == "true" ]] || die "Missing -- separator before command"
  (($#)) || die "Missing command after --"
  cmd=("$@")

  command -v jq >/dev/null 2>&1 || die "jq is required to run dev-doctor-run"
  [[ -x "$DEV_DOCTOR" ]] || die "dev-doctor.sh not found or not executable: $DEV_DOCTOR"

  result_file="$(mktemp)"
  "$DEV_DOCTOR" "${doctor_args[@]}" --json > "$result_file"
  rc=$?
  if (( rc != 0 )); then
    cat "$result_file" >&2
    rm -f "$result_file"
    return "$rc"
  fi

  if [[ "$(jq -r '.healthy // false' "$result_file")" != "true" ]]; then
    cat "$result_file" >&2
    rm -f "$result_file"
    return 2
  fi

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    dir="$(dirname "$path")"
    prepend_path_dir "$dir"
  done < <(jq -r '.checks[] | select(.status == "ok" and (.path // "") != "") | .path' "$result_file")
  rm -f "$result_file"

  export PATH
  if [[ -n "$run_cwd" ]]; then
    cd "$run_cwd" || die "Project path not found: $run_cwd"
  fi
  exec "${cmd[@]}"
}

main "$@"
