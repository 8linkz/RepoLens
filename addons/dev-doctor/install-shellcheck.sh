#!/usr/bin/env bash
# Install shellcheck as a user-local binary from upstream releases.

set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
CHECK_ONLY=false

usage() {
  cat <<'USAGE'
Usage:
  install-shellcheck.sh [--check]

Installs the latest shellcheck release into ~/.local/bin by default.
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
  p="$(command -v shellcheck 2>/dev/null || true)"
  [[ -n "$p" ]] || exit 1
  case "$p" in
    /mnt/c/*) exit 1 ;;
  esac
  shellcheck --version >/dev/null 2>&1
  exit $?
fi

have_cmd curl || die "curl is required to install shellcheck"
have_cmd jq || die "jq is required to install shellcheck"
have_cmd tar || die "tar is required to install shellcheck"

case "$(uname -s)" in
  Linux) ;;
  *) die "unsupported OS for shellcheck install: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) asset_suffix=".linux.x86_64.tar.xz" ;;
  aarch64|arm64) asset_suffix=".linux.aarch64.tar.xz" ;;
  *) die "unsupported architecture for shellcheck install: $(uname -m)" ;;
esac

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

release_json="$tmpdir/release.json"
archive="$tmpdir/shellcheck.tar.xz"
extract_dir="$tmpdir/extract"
mkdir -p "$extract_dir" "$INSTALL_DIR" || die "unable to create install directories"

curl -fsSL "https://api.github.com/repos/koalaman/shellcheck/releases/latest" -o "$release_json" \
  || die "unable to fetch latest shellcheck release metadata"

asset_url="$(jq -r --arg suffix "$asset_suffix" '
  .assets[]
  | select(.name | endswith($suffix))
  | .browser_download_url
' "$release_json" | head -n 1)"
[[ -n "$asset_url" ]] || die "no shellcheck release asset found for suffix $asset_suffix"

curl -fsSL "$asset_url" -o "$archive" || die "unable to download shellcheck asset"
tar -xJf "$archive" -C "$extract_dir" || die "unable to extract shellcheck archive"
shellcheck_bin="$(find "$extract_dir" -type f -name shellcheck -perm -u+x | head -n 1)"
if [[ -z "$shellcheck_bin" ]]; then
  shellcheck_bin="$(find "$extract_dir" -type f -name shellcheck | head -n 1)"
fi
[[ -n "$shellcheck_bin" ]] || die "shellcheck binary not found in archive"

cp "$shellcheck_bin" "$INSTALL_DIR/shellcheck" || die "unable to install shellcheck"
chmod 0755 "$INSTALL_DIR/shellcheck" || die "unable to mark shellcheck executable"
"$INSTALL_DIR/shellcheck" --version >/dev/null 2>&1 || die "installed shellcheck did not pass health check"
printf 'installed shellcheck at %s\n' "$INSTALL_DIR/shellcheck"
