#!/usr/bin/env bash
set -euo pipefail

# block-run uninstaller

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Uninstall block-run and its wrappers.

Options:
  --help, -h    Show this help message

Always removes from user directories (~/.local/bin, ~/.local/share, ~/.config).
If run as root, also removes from global directories (/usr/local, /etc).
EOF
    exit "${1:-0}"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# XDG paths
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

echo "Uninstalling block-run..."
echo

# Always remove local install
echo "Removing local install..."
rm -fv "${HOME}/.local/bin/block-run" 2>/dev/null || true
rm -rfv "${XDG_DATA_HOME}/block-run" 2>/dev/null || true
rm -rfv "${XDG_CONFIG_HOME}/block-run" 2>/dev/null || true

# If root, also remove global install
if [[ "$(id -u)" -eq 0 ]]; then
    echo
    echo "Removing global install..."
    rm -fv /usr/local/bin/block-run 2>/dev/null || true
    rm -rfv /usr/local/share/block-run 2>/dev/null || true
    rm -rfv /etc/block-run 2>/dev/null || true
else
    echo
    echo "Note: Run as root (sudo ./uninstall.sh) to also remove global install."
fi

echo
echo "Done!"
