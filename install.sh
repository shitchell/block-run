#!/usr/bin/env bash
set -euo pipefail

# block-run installer

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Install block-run and its wrappers.

Options:
  --local    Install to user directories (~/.local/bin, ~/.local/share, ~/.config)
             Default: global install to /usr/local/bin, /usr/local/share, /etc

Global install requires root privileges (use: sudo ./install.sh)
EOF
    exit "${1:-0}"
}

die() {
    echo "error: $*" >&2
    exit 1
}

# Defaults
LOCAL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)
            LOCAL=true
            shift
            ;;
        --help|-h)
            usage 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

# Determine install paths
if [[ "$LOCAL" == true ]]; then
    BIN_DIR="${HOME}/.local/bin"
    DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/block-run"
    CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/block-run"
else
    # Global install requires root
    if [[ "$(id -u)" -ne 0 ]]; then
        die "global install requires root (use: sudo ./install.sh or ./install.sh --local)"
    fi
    BIN_DIR="/usr/local/bin"
    DATA_DIR="/usr/local/share/block-run"
    CONFIG_DIR="/etc/block-run"
fi

WRAPPER_DIR="${DATA_DIR}/wrappers"

# Find script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing block-run..."
echo "  Binary:   ${BIN_DIR}/block-run"
echo "  Wrappers: ${WRAPPER_DIR}/"
echo "  Config:   ${CONFIG_DIR}/"
echo

# Create directories
mkdir -pv "$BIN_DIR" "$WRAPPER_DIR" "$CONFIG_DIR"

# Install main script
cp -v "$SCRIPT_DIR/block-run" "$BIN_DIR/block-run"
chmod -v +x "$BIN_DIR/block-run"

# Install wrappers
for wrapper in "$SCRIPT_DIR"/wrappers/*; do
    name="$(basename "$wrapper")"
    if [[ -L "$wrapper" ]]; then
        # Recreate symlink
        target="$(readlink "$wrapper")"
        ln -sfv "$target" "$WRAPPER_DIR/$name"
    else
        cp -v "$wrapper" "$WRAPPER_DIR/$name"
        chmod -v +x "$WRAPPER_DIR/$name"
    fi
done

# Create empty config if it doesn't exist
if [[ ! -f "$CONFIG_DIR/config" ]]; then
    touch "$CONFIG_DIR/config"
    echo "Created empty config: $CONFIG_DIR/config"
fi

echo
echo "Done!"

# Check if bin dir is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo
    echo "Note: $BIN_DIR is not in your PATH."
    echo "Add it with:  export PATH=\"$BIN_DIR:\$PATH\""
fi
