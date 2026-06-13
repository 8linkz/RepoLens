#!/usr/bin/env bash
# Install or verify a user-local native Linux Go toolchain for dev-doctor.

set -uo pipefail

VERSION=""
VERSION_FROM=""
CHECK_ONLY=false
INSTALL_ROOT="${DEV_DOCTOR_GO_ROOT:-$HOME/.local}"
BIN_DIR="${DEV_DOCTOR_BIN_DIR:-$HOME/.local/bin}"

usage() {
  cat <<'USAGE'
Usage:
  install-go.sh --version <version>
  install-go.sh --version-from <go.mod>
  install-go.sh --check --version-from <go.mod>

Installs Go under ~/.local/go-<version> and links go/gofmt into ~/.local/bin.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || die "--version requires a value"
        VERSION="$2"
        shift 2
        ;;
      --version-from)
        [[ $# -ge 2 ]] || die "--version-from requires a go.mod path"
        VERSION_FROM="$2"
        shift 2
        ;;
      --check)
        CHECK_ONLY=true
        shift
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

version_from_go_mod() {
  local file="$1" version
  [[ -f "$file" ]] || die "go.mod not found: $file"
  version="$(awk '$1 == "go" {print $2; exit}' "$file")"
  [[ -n "$version" ]] || die "No go directive found in $file"
  printf '%s\n' "${version#go}"
}

normalize_version() {
  local version="$1"
  version="${version#go}"
  [[ "$version" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]] || die "Unsupported Go version: $version"
  printf '%s\n' "$version"
}

go_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) die "Unsupported architecture for Go installer: $(uname -m)" ;;
  esac
}

native_go_ok() {
  local version="$1" arch="$2" go_path output
  go_path="$(command -v go 2>/dev/null || true)"
  [[ -n "$go_path" ]] || return 1
  case "$go_path" in
    /mnt/c/*) return 1 ;;
  esac
  output="$(go version 2>/dev/null || true)"
  [[ "$output" == "go version go${version} linux/${arch}" ]]
}

link_toolchain() {
  local target="$1" link="$2"
  mkdir -p "$BIN_DIR" || return 1
  if [[ -e "$link" && ! -L "$link" ]]; then
    mv "$link" "${link}.backup.$(date +%Y%m%d%H%M%S)" || return 1
  fi
  ln -sfn "$target" "$link" || return 1
  ln -sfn "$link/bin/go" "$BIN_DIR/go" || return 1
  ln -sfn "$link/bin/gofmt" "$BIN_DIR/gofmt" || return 1
}

install_go() {
  local version="$1" arch="$2" target link url archive checksum tmpdir extract_dir backup
  target="$INSTALL_ROOT/go-$version"
  link="$INSTALL_ROOT/go"

  if [[ -x "$target/bin/go" ]] && "$target/bin/go" version | grep -Fq "go${version} linux/${arch}"; then
    link_toolchain "$target" "$link" || die "Failed to link Go toolchain"
    "$BIN_DIR/go" version
    return 0
  fi

  have_cmd curl || die "curl is required to install Go"
  have_cmd tar || die "tar is required to install Go"
  mkdir -p "$INSTALL_ROOT" "$BIN_DIR" || die "Failed to create install directories"

  url="https://dl.google.com/go/go${version}.linux-${arch}.tar.gz"
  tmpdir="$(mktemp -d)"
  archive="$tmpdir/go.tgz"
  extract_dir="$tmpdir/extract"
  mkdir -p "$extract_dir" || die "Failed to create temp extraction directory"

  curl -fsSL -o "$archive" "$url" || die "Failed to download $url"
  if have_cmd sha256sum; then
    checksum="$(curl -fsSL "${url}.sha256" 2>/dev/null || true)"
    if [[ -n "$checksum" ]]; then
      checksum="${checksum%%[[:space:]]*}"
      [[ "$checksum" =~ ^[0-9a-fA-F]{64}$ ]] || die "Go archive checksum response was not a SHA-256 digest"
      printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c - >/dev/null \
        || die "Go archive checksum verification failed"
    fi
  fi

  tar -C "$extract_dir" -xzf "$archive" || die "Failed to extract Go archive"
  "$extract_dir/go/bin/go" version | grep -Fq "go${version} linux/${arch}" \
    || die "Downloaded Go toolchain version did not match go${version} linux/${arch}"

  if [[ -e "$target" ]]; then
    backup="${target}.backup.$(date +%Y%m%d%H%M%S)"
    mv "$target" "$backup" || die "Failed to move existing $target to $backup"
  fi
  mv "$extract_dir/go" "$target" || die "Failed to install Go into $target"
  rm -rf "$tmpdir"

  link_toolchain "$target" "$link" || die "Failed to link Go toolchain"
  "$BIN_DIR/go" version
}

main() {
  local version arch
  parse_args "$@"
  if [[ -z "$VERSION" && -n "$VERSION_FROM" ]]; then
    VERSION="$(version_from_go_mod "$VERSION_FROM")"
  fi
  [[ -n "$VERSION" ]] || die "Pass --version or --version-from"
  VERSION="$(normalize_version "$VERSION")"
  arch="$(go_arch)"

  if $CHECK_ONLY; then
    native_go_ok "$VERSION" "$arch"
    return $?
  fi

  if native_go_ok "$VERSION" "$arch"; then
    go version
    return 0
  fi

  install_go "$VERSION" "$arch"
}

main "$@"
