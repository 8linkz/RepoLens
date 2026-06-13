#!/usr/bin/env bash
# Install semgrep as an isolated user-local pipx application.

set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
CHECK_ONLY=false

usage() {
  cat <<'USAGE'
Usage:
  install-semgrep.sh [--check]

Installs semgrep through pipx and exposes the binary in ~/.local/bin.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

while (($#)); do
  case "$1" in
    --check)
      CHECK_ONLY=true
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if $CHECK_ONLY; then
  p="$(command -v semgrep 2>/dev/null || true)"
  [[ -n "$p" ]] || exit 1
  case "$p" in
    /mnt/c/*) exit 1 ;;
  esac
  semgrep --version >/dev/null 2>&1
  exit $?
fi

have_cmd pipx || die "pipx is required to install semgrep. Install it with: sudo apt-get install -y pipx"
mkdir -p "$INSTALL_DIR" || die "unable to create $INSTALL_DIR"

PIPX_BIN_DIR="$INSTALL_DIR" pipx install --force semgrep || die "pipx failed to install semgrep"
PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/semgrep" --version >/dev/null 2>&1 \
  || die "installed semgrep did not pass health check"
printf 'installed semgrep at %s\n' "$INSTALL_DIR/semgrep"
