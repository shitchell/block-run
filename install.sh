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

Global install requires sudo.
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
    SUDO=""
else
    BIN_DIR="/usr/local/bin"
    DATA_DIR="/usr/local/share/block-run"
    CONFIG_DIR="/etc/block-run"
    SUDO="sudo"
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
$SUDO mkdir -p "$BIN_DIR" "$WRAPPER_DIR" "$CONFIG_DIR"

# Install main script
$SUDO cp "$SCRIPT_DIR/block-run" "$BIN_DIR/block-run"
$SUDO chmod +x "$BIN_DIR/block-run"

# Install wrappers
for wrapper in "$SCRIPT_DIR"/wrappers/*; do
    name="$(basename "$wrapper")"
    if [[ -L "$wrapper" ]]; then
        # Recreate symlink
        target="$(readlink "$wrapper")"
        $SUDO ln -sf "$target" "$WRAPPER_DIR/$name"
    else
        $SUDO cp "$wrapper" "$WRAPPER_DIR/$name"
        $SUDO chmod +x "$WRAPPER_DIR/$name"
    fi
done

# Create empty config if it doesn't exist
if [[ ! -f "$CONFIG_DIR/config" ]]; then
    $SUDO touch "$CONFIG_DIR/config"
fi

echo "Done!"

# Check if bin dir is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo
    echo "Note: $BIN_DIR is not in your PATH."
    echo "Add it with:  export PATH=\"$BIN_DIR:\$PATH\""
fi
