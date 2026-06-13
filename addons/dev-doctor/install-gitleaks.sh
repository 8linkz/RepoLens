#!/usr/bin/env bash
# Install gitleaks as a user-local RepoLens secret-scanning dependency.

set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
CHECK_ONLY=false

usage() {
  cat <<'USAGE'
Usage:
  install-gitleaks.sh [--check]

Installs the latest gitleaks release into ~/.local/bin by default.
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
  p="$(command -v gitleaks 2>/dev/null || true)"
  [[ -n "$p" ]] || exit 1
  case "$p" in
    /mnt/c/*) exit 1 ;;
  esac
  gitleaks version >/dev/null 2>&1
  exit $?
fi

have_cmd curl || die "curl is required to install gitleaks"
have_cmd jq || die "jq is required to install gitleaks"
have_cmd tar || die "tar is required to install gitleaks"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
  linux|darwin) ;;
  *) die "unsupported OS for gitleaks install: $os" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch="x64" ;;
  aarch64|arm64) arch="arm64" ;;
  armv7l) arch="armv7" ;;
  armv6l) arch="armv6" ;;
  *) die "unsupported architecture for gitleaks install: $(uname -m)" ;;
esac

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

release_json="$tmpdir/release.json"
archive="$tmpdir/gitleaks.tar.gz"
extract_dir="$tmpdir/extract"
mkdir -p "$extract_dir" "$INSTALL_DIR" || die "unable to create install directories"

curl -fsSL "https://api.github.com/repos/gitleaks/gitleaks/releases/latest" -o "$release_json" \
  || die "unable to fetch latest gitleaks release metadata"

asset_suffix="_${os}_${arch}.tar.gz"
asset_url="$(jq -r --arg suffix "$asset_suffix" '
  .assets[]
  | select(.name | endswith($suffix))
  | .browser_download_url
' "$release_json" | head -n 1)"
[[ -n "$asset_url" ]] || die "no gitleaks release asset found for suffix $asset_suffix"

asset_digest="$(jq -r --arg url "$asset_url" '
  .assets[]
  | select(.browser_download_url == $url)
  | .digest // ""
' "$release_json" | head -n 1)"

curl -fsSL "$asset_url" -o "$archive" || die "unable to download gitleaks asset"
if [[ "$asset_digest" == sha256:* ]] && have_cmd sha256sum; then
  expected="${asset_digest#sha256:}"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || die "gitleaks checksum mismatch"
fi

tar -xzf "$archive" -C "$extract_dir" || die "unable to extract gitleaks archive"
gitleaks_bin="$(find "$extract_dir" -type f -name gitleaks -perm -u+x | head -n 1)"
if [[ -z "$gitleaks_bin" ]]; then
  gitleaks_bin="$(find "$extract_dir" -type f -name gitleaks | head -n 1)"
fi
[[ -n "$gitleaks_bin" ]] || die "gitleaks binary not found in archive"

cp "$gitleaks_bin" "$INSTALL_DIR/gitleaks" || die "unable to install gitleaks"
chmod 0755 "$INSTALL_DIR/gitleaks" || die "unable to mark gitleaks executable"
"$INSTALL_DIR/gitleaks" version >/dev/null 2>&1 || die "installed gitleaks did not pass health check"
printf 'installed gitleaks at %s\n' "$INSTALL_DIR/gitleaks"
