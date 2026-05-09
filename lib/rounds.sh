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

# RepoLens - round-aware lens execution driver

# run_rounds <rounds_total> <lens_list_array_name>
#   Runs the current per-lens dispatch path for rounds 1..rounds_total.
#   The second argument is the name of a Bash array, for example LENS_LIST.
#   This deliberately avoids Bash namerefs so the module stays compatible
#   with the project's Bash 4 baseline.
#
#   Required globals are provided by repolens.sh when R4 wires this in:
#   PARALLEL, MAX_PARALLEL, LOG_BASE, SUMMARY_FILE, MAX_ISSUES,
#   GLOBAL_ISSUES_CREATED, and TOTAL_LENSES.
#
#   R1 only validates the round count; it does not define per-round issue
#   budgets. Keep GLOBAL_ISSUES_CREATED cumulative across rounds until that
#   contract changes.

_rounds_valid_array_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

_rounds_marker_path() {
  local round="$1"
  printf '%s/.rounds/round-%s.completed\n' "$LOG_BASE" "$round"
}

_rounds_lens_completion_path() {
  local round="$1"
  printf '%s/.rounds/round-%s.lenses.completed\n' "$LOG_BASE" "$round"
}

_rounds_restore_completed_lenses_file() {
  local had_completed_file="$1" original_completed_file="$2"

  if (( had_completed_file )); then
    completed_lenses_file="$original_completed_file"
  else
    unset completed_lenses_file
  fi
}

is_round_completed() {
  local round="$1"
  local marker
  marker="$(_rounds_marker_path "$round")"
  [[ -f "$marker" ]]
}

mark_round_completed() {
  local round="$1"
  local marker marker_dir
  marker="$(_rounds_marker_path "$round")"
  marker_dir="${marker%/*}"
  mkdir -p "$marker_dir"
  : > "$marker"
}

run_meta_orchestrator() {
  local round="$1" next_round="$2"
  log_info "[round $round] Meta-orchestrator handoff to round $next_round is pending implementation"
  return 0
}

_round_digest_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$*"
  else
    printf 'WARN: %s\n' "$*" >&2
  fi
}

_round_digest_repo_root() {
  local rounds_lib_dir
  rounds_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "${rounds_lib_dir%/lib}"
}

_round_digest_audit_domains() {
  local domains_file="$1"

  if [[ ! -f "$domains_file" ]]; then
    return 1
  fi

  awk '
    /"id"[[:space:]]*:/ {
      id = $0
      sub(/^.*"id"[[:space:]]*:[[:space:]]*"/, "", id)
      sub(/".*$/, "", id)
      mode = ""
    }
    /"mode"[[:space:]]*:/ {
      mode = $0
      sub(/^.*"mode"[[:space:]]*:[[:space:]]*"/, "", mode)
      sub(/".*$/, "", mode)
    }
    /^[[:space:]]*}[,]?[[:space:]]*$/ {
      if (id != "" && mode != "discover" && mode != "deploy" && mode != "opensource" && mode != "content") {
        print id
      }
      id = ""
      mode = ""
    }
  ' "$domains_file"
}

_round_digest_registered_lenses() {
  local domains_file="$1"

  if [[ ! -f "$domains_file" ]]; then
    return 1
  fi

  awk '
    {
      line = $0
      if (!collecting) {
        if (line !~ /"lenses"[[:space:]]*:/) {
          next
        }
        collecting = 1
        sub(/^.*"lenses"[[:space:]]*:[[:space:]]*/, "", line)
      }

      scan = line
      while (match(scan, /"[^"]+"/)) {
        value = substr(scan, RSTART + 1, RLENGTH - 2)
        if (value != "") {
          print value
        }
        scan = substr(scan, RSTART + RLENGTH)
      }

      if (line ~ /\]/) {
        collecting = 0
      }
    }
  ' "$domains_file"
}

_round_digest_frontmatter_block() {
  local file="$1"

  awk '
    NR == 1 && $0 == "---" {
      in_frontmatter = 1
      next
    }
    NR == 1 {
      exit 1
    }
    in_frontmatter && $0 == "---" {
      found_end = 1
      exit 0
    }
    in_frontmatter {
      print
    }
    END {
      if (!found_end) {
        exit 1
      }
    }
  ' "$file"
}

_round_digest_trim_yaml_value() {
  local value="$*"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s\n' "$value"
}

_round_digest_frontmatter_values() {
  local key="$1"

  awk -v key="$key" '
    function emit(value) {
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      if (value != "") {
        print value
      }
    }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
      collecting = 1
      value = $0
      sub("^[[:space:]]*" key "[[:space:]]*:[[:space:]]*", "", value)
      if (value != "") {
        emit(value)
        exit 0
      }
      next
    }
    collecting && $0 ~ "^[[:space:]]*-[[:space:]]*" {
      value = $0
      sub("^[[:space:]]*-[[:space:]]*", "", value)
      emit(value)
      next
    }
    collecting && $0 ~ "^[A-Za-z0-9_][A-Za-z0-9_-]*[[:space:]]*:" {
      exit 0
    }
  '
}

_round_digest_frontmatter_scalar() {
  local key="$1" value

  value="$(_round_digest_frontmatter_values "$key" | sed -n '1p')"
  _round_digest_trim_yaml_value "$value"
}

_round_digest_sanitize_identifier() {
  local value="$*"

  value="$(_round_digest_trim_yaml_value "$value")"
  printf '%s\n' "$value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E \
        -e 's/[^a-z0-9]+/-/g' \
        -e 's/-+/-/g' \
        -e 's/^-+//' \
        -e 's/-+$//'
}

_round_digest_normalize_label() {
  _round_digest_sanitize_identifier "$@"
}

_round_digest_rank_lens_categories() {
  local lens="$1" limit="$2" key category count

  for key in "${!_round_digest_lens_category_counts[@]}"; do
    [[ "$key" == "$lens|"* ]] || continue
    category="${key#*|}"
    count="${_round_digest_lens_category_counts[$key]}"
    printf '%s\t%s\n' "$count" "$category"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 | head -n "$limit" | cut -f2-
}

_round_digest_rank_themes() {
  local limit="$1" category count

  for category in "${!_round_digest_category_counts[@]}"; do
    count="${_round_digest_category_counts[$category]}"
    printf '%s\t%s\n' "$count" "$category"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 | head -n "$limit"
}

_round_digest_join_lines() {
  local result="" line sanitized

  while IFS= read -r line; do
    sanitized="$(_round_digest_sanitize_identifier "$line")"
    [[ -n "$sanitized" ]] || continue
    if [[ -n "$result" ]]; then
      result+=", "
    fi
    result+="$sanitized"
  done

  printf '%s\n' "${result:-none}"
}

build_round_digest() {
  local round_dir="${1:-}" lens_outputs_dir digest_path repo_root domains_file
  local old_nullglob file frontmatter severity domain lens category normalized category_seen
  local suspect_file audit_domain audit_total coverage_count coverage_domains registered_lens display_lens
  local tmp_digest digest_lines
  local -a md_files=() sorted_lenses=() touched_domains=()
  local -A _round_digest_lens_counts=()
  local -A _round_digest_lens_category_counts=()
  local -A _round_digest_category_counts=()
  local -A _round_digest_touched_domains=()
  local -A _round_digest_audit_domain_set=()
  local -A _round_digest_registered_lens_set=()
  local -A _round_digest_suspect_file_counts=()

  if [[ -z "$round_dir" ]]; then
    _round_digest_warn "build_round_digest requires a round directory"
    return 2
  fi

  if ! mkdir -p "$round_dir"; then
    _round_digest_warn "Unable to create round directory for digest: $round_dir"
    return 1
  fi

  lens_outputs_dir="$round_dir/lens-outputs"
  digest_path="$round_dir/digest.md"
  repo_root="$(_round_digest_repo_root)"
  domains_file="$repo_root/config/domains.json"

  while IFS= read -r audit_domain; do
    [[ -n "$audit_domain" ]] || continue
    _round_digest_audit_domain_set["$audit_domain"]=1
  done < <(_round_digest_audit_domains "$domains_file" || true)
  while IFS= read -r registered_lens; do
    [[ -n "$registered_lens" ]] || continue
    _round_digest_registered_lens_set["$registered_lens"]=1
  done < <(_round_digest_registered_lenses "$domains_file" || true)
  audit_total="${#_round_digest_audit_domain_set[@]}"
  if (( audit_total == 0 )); then
    audit_total=27
  fi

  if [[ -d "$lens_outputs_dir" ]]; then
    old_nullglob="$(shopt -p nullglob || true)"
    shopt -s nullglob
    md_files=("$lens_outputs_dir"/*.md)
    eval "$old_nullglob"
    if (( ${#md_files[@]} > 0 )); then
      mapfile -t md_files < <(printf '%s\n' "${md_files[@]}" | LC_ALL=C sort)
    fi
  fi

  for file in "${md_files[@]}"; do
    if ! frontmatter="$(_round_digest_frontmatter_block "$file")"; then
      _round_digest_warn "Skipping malformed lens output $(basename "$file"): missing or unterminated YAML frontmatter"
      continue
    fi

    severity="$(printf '%s\n' "$frontmatter" | _round_digest_frontmatter_scalar "severity")"
    domain="$(printf '%s\n' "$frontmatter" | _round_digest_frontmatter_scalar "domain")"
    lens="$(printf '%s\n' "$frontmatter" | _round_digest_frontmatter_scalar "lens")"

    if [[ -z "$severity" || -z "$domain" || -z "$lens" ]]; then
      _round_digest_warn "Skipping malformed lens output $(basename "$file"): required frontmatter keys severity, domain, and lens are required"
      continue
    fi
    if [[ -z "${_round_digest_registered_lens_set[$lens]:-}" ]]; then
      _round_digest_warn "Skipping untrusted lens output $(basename "$file"): lens id is not registered"
      continue
    fi

    _round_digest_lens_counts["$lens"]=$(( ${_round_digest_lens_counts["$lens"]:-0} + 1 ))
    if [[ -n "${_round_digest_audit_domain_set[$domain]:-}" ]]; then
      _round_digest_touched_domains["$domain"]=1
    fi

    category_seen=0
    while IFS= read -r category; do
      normalized="$(_round_digest_normalize_label "$category")"
      [[ -n "$normalized" ]] || continue
      category_seen=1
      _round_digest_lens_category_counts["$lens|$normalized"]=$(( ${_round_digest_lens_category_counts["$lens|$normalized"]:-0} + 1 ))
      _round_digest_category_counts["$normalized"]=$(( ${_round_digest_category_counts["$normalized"]:-0} + 1 ))
    done < <(printf '%s\n' "$frontmatter" | _round_digest_frontmatter_values "root_cause_category")

    if (( category_seen == 0 )); then
      _round_digest_lens_category_counts["$lens|uncategorized"]=$(( ${_round_digest_lens_category_counts["$lens|uncategorized"]:-0} + 1 ))
      _round_digest_category_counts["uncategorized"]=$(( ${_round_digest_category_counts["uncategorized"]:-0} + 1 ))
    fi

    while IFS= read -r suspect_file; do
      suspect_file="$(_round_digest_trim_yaml_value "$suspect_file")"
      [[ -n "$suspect_file" ]] || continue
      _round_digest_suspect_file_counts["$suspect_file"]=$(( ${_round_digest_suspect_file_counts["$suspect_file"]:-0} + 1 ))
    done < <(printf '%s\n' "$frontmatter" | _round_digest_frontmatter_values "suspect_files")
  done

  tmp_digest="${digest_path}.tmp.$$"
  {
    printf '# Round Digest\n\n'

    if (( ${#_round_digest_lens_counts[@]} == 0 )); then
      printf 'No findings this round.\n\n'
    else
      mapfile -t sorted_lenses < <(printf '%s\n' "${!_round_digest_lens_counts[@]}" | LC_ALL=C sort)
      printf '## Lens Findings\n'
      for lens in "${sorted_lenses[@]}"; do
        display_lens="$(_round_digest_sanitize_identifier "$lens")"
        [[ -n "$display_lens" ]] || continue
        printf -- '- %s: %s finding' "$display_lens" "${_round_digest_lens_counts[$lens]}"
        if (( ${_round_digest_lens_counts[$lens]} != 1 )); then
          printf 's'
        fi
        printf '; top categories: %s\n' "$(_round_digest_join_lines < <(_round_digest_rank_lens_categories "$lens" 3))"
      done
      printf '\n'

      printf '## Top Themes\n'
      if (( ${#_round_digest_category_counts[@]} == 0 )); then
        printf 'none\n'
      else
        local rank=1 line count theme
        while IFS=$'\t' read -r count theme; do
          theme="$(_round_digest_sanitize_identifier "$theme")"
          [[ -n "$theme" ]] || continue
          printf '%s. %s (%s)\n' "$rank" "$theme" "$count"
          rank=$((rank + 1))
        done < <(_round_digest_rank_themes 3)
      fi
      printf '\n'
    fi

    if (( ${#_round_digest_touched_domains[@]} > 0 )); then
      mapfile -t touched_domains < <(printf '%s\n' "${!_round_digest_touched_domains[@]}" | LC_ALL=C sort)
      coverage_count="${#touched_domains[@]}"
      coverage_domains="$(_round_digest_join_lines < <(printf '%s\n' "${touched_domains[@]}"))"
    else
      coverage_count=0
      coverage_domains="none"
    fi

    printf '## Coverage\n'
    printf 'Touched %s/%s audit domains: %s\n' "$coverage_count" "$audit_total" "$coverage_domains"
  } > "$tmp_digest" || {
    rm -f "$tmp_digest"
    return 1
  }

  digest_lines="$(wc -l < "$tmp_digest" | tr -d '[:space:]')"
  if [[ "$digest_lines" =~ ^[0-9]+$ && "$digest_lines" -gt 500 ]]; then
    head -n 499 "$tmp_digest" > "$digest_path"
    printf 'Digest truncated at 500 lines.\n' >> "$digest_path"
    rm -f "$tmp_digest"
  else
    mv "$tmp_digest" "$digest_path"
  fi
}

_rounds_record_skipped_lenses() {
  local skip_entry skip_domain skip_lens

  for skip_entry in "$@"; do
    skip_domain="${skip_entry%%/*}"
    skip_lens="${skip_entry#*/}"
    if ! is_lens_completed "$skip_entry"; then
      record_lens "$SUMMARY_FILE" "$skip_domain" "$skip_lens" 0 "skipped" 0 0
    fi
  done
}

run_rounds() {
  local rounds_total="$1" lens_list_var="$2"
  local -a lens_list=()
  local round lens_entry parallel_count local_count lens_total
  local original_completed_lenses_file had_completed_lenses_file
  local round_completed_lenses_file round_completed_lenses_dir round_rc

  if [[ ! "$rounds_total" =~ ^[1-9][0-9]*$ ]]; then
    log_warn "Invalid rounds_total: $rounds_total"
    return 2
  fi
  if ! _rounds_valid_array_name "$lens_list_var"; then
    log_warn "Invalid lens list array name: $lens_list_var"
    return 2
  fi

  eval "lens_list=(\"\${${lens_list_var}[@]}\")"
  lens_total="${TOTAL_LENSES:-${#lens_list[@]}}"

  # shellcheck disable=SC2046 # The issue explicitly requires seq-driven rounds.
  for round in $(seq 1 "$rounds_total"); do
    if is_round_completed "$round"; then
      log_info "[round $round/$rounds_total] Skipping completed round"
      continue
    fi

    if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
      set_stop_reason "$SUMMARY_FILE" "rate-limited"
      return 1
    fi

    if (( rounds_total > 1 )); then
      log_info "[round $round/$rounds_total] Starting"
    fi

    had_completed_lenses_file=0
    original_completed_lenses_file="${completed_lenses_file:-}"
    if [[ ${completed_lenses_file+x} == x ]]; then
      had_completed_lenses_file=1
    fi

    if (( rounds_total > 1 )); then
      round_completed_lenses_file="$(_rounds_lens_completion_path "$round")"
      round_completed_lenses_dir="${round_completed_lenses_file%/*}"
      if ! mkdir -p "$round_completed_lenses_dir" || ! touch "$round_completed_lenses_file"; then
        _rounds_restore_completed_lenses_file "$had_completed_lenses_file" "$original_completed_lenses_file"
        return 1
      fi
      completed_lenses_file="$round_completed_lenses_file"
    fi

    if ${PARALLEL:-false}; then
      log_info "Running in parallel mode (max ${MAX_PARALLEL:-8} concurrent)"
      init_parallel "$LOG_BASE/.semaphore" "${MAX_PARALLEL:-8}"

      parallel_count=0
      for lens_entry in "${lens_list[@]}"; do
        # Skip spawning new lenses if a sibling tripped the rate-limit detector.
        # In-flight children continue; the summary still records skipped lenses
        # so --resume picks them up.
        if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
          log_warn "Rate-limit abort detected. Skipping remaining lenses."
          _rounds_record_skipped_lenses "${lens_list[@]:$parallel_count}"
          set_stop_reason "$SUMMARY_FILE" "rate-limited"
          break
        fi
        parallel_count=$((parallel_count + 1))
        spawn_lens "$lens_entry" run_lens "$lens_entry"
      done

      if ! wait_all; then
        log_warn "Some lenses exited with errors."
      fi

      # Children may have tripped the abort after the spawn loop finished.
      # Make sure the stop_reason is recorded even then.
      if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
        set_stop_reason "$SUMMARY_FILE" "rate-limited"
      fi
    else
      log_info "Running in sequential mode"
      local_count=0
      for lens_entry in "${lens_list[@]}"; do
        # Check for rate-limit abort from a previous lens in this run.
        if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
          log_warn "Rate-limit abort detected. Skipping remaining lenses."
          _rounds_record_skipped_lenses "${lens_list[@]:$local_count}"
          set_stop_reason "$SUMMARY_FILE" "rate-limited"
          break
        fi

        # Check global issue budget before starting next lens.
        if [[ -n "${MAX_ISSUES:-}" && "${GLOBAL_ISSUES_CREATED:-0}" -ge "$MAX_ISSUES" ]]; then
          log_info "Global issue budget exhausted (${GLOBAL_ISSUES_CREATED:-0}/$MAX_ISSUES). Skipping remaining lenses."
          _rounds_record_skipped_lenses "${lens_list[@]:$local_count}"
          set_stop_reason "$SUMMARY_FILE" "max-issues-reached"
          break
        fi

        local_count=$((local_count + 1))
        log_info "--- Lens $local_count/$lens_total ---"
        run_lens "$lens_entry"
      done
    fi

    if [[ -f "$LOG_BASE/.rate-limit-abort" ]]; then
      set_stop_reason "$SUMMARY_FILE" "rate-limited"
      _rounds_restore_completed_lenses_file "$had_completed_lenses_file" "$original_completed_lenses_file"
      return 1
    fi

    mark_round_completed "$round"
    round_rc=$?
    _rounds_restore_completed_lenses_file "$had_completed_lenses_file" "$original_completed_lenses_file"
    if (( round_rc != 0 )); then
      return "$round_rc"
    fi

    if (( round < rounds_total )); then
      run_meta_orchestrator "$round" "$((round + 1))" || return $?
    fi
  done
}
