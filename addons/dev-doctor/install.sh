#!/usr/bin/env bash
# Install a user-local dev-doctor wrapper and bundled profiles.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${DEV_DOCTOR_BIN_DIR:-$HOME/.local/bin}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PROFILE_TARGET_DIR="${DEV_DOCTOR_PROFILE_DIR:-$CONFIG_HOME/dev-doctor/profiles}"
WRAPPER="$BIN_DIR/dev-doctor"

mkdir -p "$BIN_DIR" "$PROFILE_TARGET_DIR" || {
  printf 'ERROR: unable to create install directories\n' >&2
  exit 1
}

cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
exec "$SCRIPT_DIR/dev-doctor.sh" "\$@"
EOF
chmod +x "$WRAPPER" || {
  printf 'ERROR: unable to mark wrapper executable: %s\n' "$WRAPPER" >&2
  exit 1
}

if [[ -d "$SCRIPT_DIR/profiles" ]]; then
  cp "$SCRIPT_DIR"/profiles/*.json "$PROFILE_TARGET_DIR"/ 2>/dev/null || true
fi

printf 'Installed dev-doctor wrapper: %s\n' "$WRAPPER"
printf 'Installed profiles: %s\n' "$PROFILE_TARGET_DIR"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    printf 'Add this to your shell profile if needed:\n'
    printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
    ;;
esac
