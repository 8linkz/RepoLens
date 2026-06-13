#!/usr/bin/env bash
# Install trivy as a user-local binary from upstream releases.

set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
CHECK_ONLY=false

usage() {
  cat <<'USAGE'
Usage:
  install-trivy.sh [--check]

Installs the latest trivy release into ~/.local/bin by default.
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
  p="$(command -v trivy 2>/dev/null || true)"
  [[ -n "$p" ]] || exit 1
  case "$p" in
    /mnt/c/*) exit 1 ;;
  esac
  trivy --version >/dev/null 2>&1
  exit $?
fi

have_cmd curl || die "curl is required to install trivy"
have_cmd jq || die "jq is required to install trivy"
have_cmd tar || die "tar is required to install trivy"

case "$(uname -s)" in
  Linux) ;;
  *) die "unsupported OS for trivy install: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) asset_suffix="_Linux-64bit.tar.gz" ;;
  aarch64|arm64) asset_suffix="_Linux-ARM64.tar.gz" ;;
  *) die "unsupported architecture for trivy install: $(uname -m)" ;;
esac

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

release_json="$tmpdir/release.json"
checksums="$tmpdir/checksums.txt"
extract_dir="$tmpdir/extract"
mkdir -p "$extract_dir" "$INSTALL_DIR" || die "unable to create install directories"

curl -fsSL "https://api.github.com/repos/aquasecurity/trivy/releases/latest" -o "$release_json" \
  || die "unable to fetch latest trivy release metadata"

asset_name="$(jq -r --arg suffix "$asset_suffix" '
  .assets[]
  | select(.name | endswith($suffix))
  | .name
' "$release_json" | head -n 1)"
asset_url="$(jq -r --arg name "$asset_name" '
  .assets[]
  | select(.name == $name)
  | .browser_download_url
' "$release_json" | head -n 1)"
checksum_url="$(jq -r '
  .assets[]
  | select(.name | endswith("_checksums.txt"))
  | .browser_download_url
' "$release_json" | head -n 1)"
[[ -n "$asset_name" && -n "$asset_url" ]] || die "no trivy release asset found for suffix $asset_suffix"

archive="$tmpdir/$asset_name"
curl -fsSL "$asset_url" -o "$archive" || die "unable to download trivy asset"
if [[ -n "$checksum_url" ]] && have_cmd sha256sum; then
  curl -fsSL "$checksum_url" -o "$checksums" || die "unable to download trivy checksums"
  grep -E "[[:space:]]${asset_name}$" "$checksums" > "$tmpdir/checksum-one.txt" \
    || die "no checksum entry found for $asset_name"
  (cd "$tmpdir" && sha256sum -c checksum-one.txt) >/dev/null \
    || die "trivy checksum verification failed"
fi

tar -xzf "$archive" -C "$extract_dir" || die "unable to extract trivy archive"
trivy_bin="$(find "$extract_dir" -type f -name trivy -perm -u+x | head -n 1)"
if [[ -z "$trivy_bin" ]]; then
  trivy_bin="$(find "$extract_dir" -type f -name trivy | head -n 1)"
fi
[[ -n "$trivy_bin" ]] || die "trivy binary not found in archive"

cp "$trivy_bin" "$INSTALL_DIR/trivy" || die "unable to install trivy"
chmod 0755 "$INSTALL_DIR/trivy" || die "unable to mark trivy executable"
"$INSTALL_DIR/trivy" --version >/dev/null 2>&1 || die "installed trivy did not pass health check"
printf 'installed trivy at %s\n' "$INSTALL_DIR/trivy"
