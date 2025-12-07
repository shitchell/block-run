#!/usr/bin/env bash
set -euo pipefail

# block-run: Execute code files block-by-block, like a notebook
# Blocks are separated by blank lines (two+ newlines)
# Dispatches to language-specific wrappers

#-----------------------------------------------------------------------------
# Directory structure (XDG-compliant)
#-----------------------------------------------------------------------------
# Wrappers:
#   1. ~/.local/share/block-run/wrappers/  (user, highest priority)
#   2. /usr/local/share/block-run/wrappers/ (system)
#
# Config:
#   1. ~/.config/block-run/config  (user, highest priority)
#   2. /etc/block-run/config       (system)
#-----------------------------------------------------------------------------

# XDG defaults
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# Search paths (user first, then system)
WRAPPER_DIRS=(
    "$XDG_DATA_HOME/block-run/wrappers"
    "/usr/local/share/block-run/wrappers"
)
CONFIG_FILES=(
    "$XDG_CONFIG_HOME/block-run/config"
    "/etc/block-run/config"
)

# Marker character for chunk display protocol (ASCII Group Separator)
MARKER=$'\x1d'

# Colors
BOLD=$'\e[1m'
CYAN=$'\e[36m'
DIM=$'\e[2m'
RESET=$'\e[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <script>

Run a script block-by-block, showing output after each block.
Blocks are separated by blank lines.

Options:
  --hierarchical    Use '## ' headers to separate blocks instead of blank lines
  --help            Show this help message

The interpreter is determined from the shebang line.

Wrapper search paths:
$(for d in "${WRAPPER_DIRS[@]}"; do echo "  - $d"; done)

Config search paths:
$(for f in "${CONFIG_FILES[@]}"; do echo "  - $f"; done)
EOF
    exit "${1:-0}"
}

die() {
    echo "error: $*" >&2
    exit 1
}

# Extract binary path from shebang
# Handles: #!/path/to/bin, #!/usr/bin/env bin, #!/path/to/bin args
parse_shebang() {
    local shebang="$1"

    # Remove #! prefix
    shebang="${shebang#\#!}"
    shebang="${shebang# }"  # trim leading space if present

    # Handle /usr/bin/env case
    if [[ "$shebang" =~ ^/usr/bin/env[[:space:]]+([^[:space:]]+) ]]; then
        local cmd="${BASH_REMATCH[1]}"
        # Resolve to full path
        if command -v "$cmd" &>/dev/null; then
            command -v "$cmd"
        else
            echo "$cmd"
        fi
        return
    fi

    # Direct path - extract just the binary (first word)
    echo "${shebang%% *}"
}

# Find wrapper for a given binary
find_wrapper() {
    local binary="$1"
    local basename="${binary##*/}"
    local wrapper_name=""

    # 1. Check config files for exact path match (user config first)
    for config_file in "${CONFIG_FILES[@]}"; do
        if [[ -f "$config_file" ]]; then
            wrapper_name=$(grep "^${binary}=" "$config_file" 2>/dev/null | cut -d= -f2 | head -1)
            if [[ -n "$wrapper_name" ]]; then
                break
            fi
        fi
    done

    # 2. If no config match, use basename as wrapper name
    [[ -z "$wrapper_name" ]] && wrapper_name="$basename"

    # 3. Search wrapper directories (user first, then system)
    for wrapper_dir in "${WRAPPER_DIRS[@]}"; do
        if [[ -x "$wrapper_dir/$wrapper_name" ]]; then
            echo "$wrapper_dir/$wrapper_name"
            return 0
        fi
    done

    # 4. No wrapper found
    return 1
}

# Map binary basename to pygmentize lexer
get_lexer() {
    local binary="$1"
    local basename="${binary##*/}"

    case "$basename" in
        python|python3|python2) echo "python" ;;
        bash|sh|zsh|ksh)        echo "bash" ;;
        node|nodejs)            echo "javascript" ;;
        ts-node|tsx)            echo "typescript" ;;
        mariadb|mysql|sqlite3)  echo "sql" ;;
        ruby|irb)               echo "ruby" ;;
        perl)                   echo "perl" ;;
        php)                    echo "php" ;;
        lua)                    echo "lua" ;;
        *)                      echo "text" ;;
    esac
}

# Syntax highlight code
highlight() {
    local code="$1"
    local lexer="$2"

    if command -v pygmentize &>/dev/null && [[ "$lexer" != "text" ]]; then
        echo "$code" | pygmentize -l "$lexer"
    else
        echo "$code"
    fi
}

# Print separator line
separator() {
    echo "${DIM}─────────────────────────────────────────${RESET}"
}

# Split content into blocks (separated by blank lines)
# Outputs each block as a null-terminated string for safe handling
split_blocks_blank_lines() {
    local content="$1"
    local current_block=""
    local in_block=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
            # Empty line
            if [[ "$in_block" == true && -n "$current_block" ]]; then
                # End of block - output it
                printf '%s\0' "$current_block"
                current_block=""
                in_block=false
            fi
        else
            # Non-empty line
            if [[ "$in_block" == true ]]; then
                current_block+=$'\n'"$line"
            else
                current_block="$line"
                in_block=true
            fi
        fi
    done <<< "$content"

    # Output final block if any
    if [[ -n "$current_block" ]]; then
        printf '%s\0' "$current_block"
    fi
}

# Split content into blocks (separated by ## headers)
split_blocks_hierarchical() {
    local content="$1"
    local current_block=""
    local first=true

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^##\  ]]; then
            # Header line - start new block
            if [[ -n "$current_block" ]]; then
                printf '%s\0' "$current_block"
            fi
            current_block="$line"
            first=false
        else
            # Regular line
            if [[ -n "$current_block" ]]; then
                current_block+=$'\n'"$line"
            elif [[ -n "$line" ]]; then
                # Content before first header
                current_block="$line"
            fi
        fi
    done <<< "$content"

    # Output final block if any
    if [[ -n "$current_block" ]]; then
        printf '%s\0' "$current_block"
    fi
}

# Process wrapper output, handling chunk display markers
process_output() {
    local lexer="$1"
    shift
    local blocks=("$@")

    local marker_regex="^${MARKER}\{([0-9]+)\}${MARKER}$"

    while IFS= read -r line; do
        if [[ "$line" =~ $marker_regex ]]; then
            local idx="${BASH_REMATCH[1]}"
            local block_num=$((idx + 1))

            # Print header
            echo "${CYAN}# Block ${block_num}${RESET}"

            # Print highlighted code
            highlight "${blocks[$idx]}" "$lexer"

            # Print separator
            separator
        else
            # Pass through as-is
            echo "$line"
        fi
    done
}

main() {
    local script=""
    local split_mode="blank_lines"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hierarchical)
                split_mode="hierarchical"
                shift
                ;;
            --help|-h)
                usage 0
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                [[ -z "$script" ]] || die "multiple scripts specified"
                script="$1"
                shift
                ;;
        esac
    done

    [[ -n "$script" ]] || die "no script specified"
    [[ -f "$script" ]] || die "script not found: $script"

    # Read shebang
    local shebang
    shebang=$(head -1 "$script")
    [[ "$shebang" =~ ^#! ]] || die "no shebang found in $script"

    # Parse binary from shebang
    local binary
    binary=$(parse_shebang "$shebang")
    [[ -n "$binary" ]] || die "could not parse shebang: $shebang"

    # Find wrapper
    local wrapper
    if ! wrapper=$(find_wrapper "$binary"); then
        die "no wrapper found for: $binary (basename: ${binary##*/})"
    fi

    # Read content (skip shebang)
    local content
    content=$(tail -n +2 "$script")

    # Split into blocks
    local blocks=()
    if [[ "$split_mode" == "hierarchical" ]]; then
        while IFS= read -r -d '' block; do
            blocks+=("$block")
        done < <(split_blocks_hierarchical "$content")
    else
        while IFS= read -r -d '' block; do
            blocks+=("$block")
        done < <(split_blocks_blank_lines "$content")
    fi

    [[ ${#blocks[@]} -gt 0 ]] || die "no blocks found in script"

    # Get lexer for syntax highlighting
    local lexer
    lexer=$(get_lexer "$binary")

    # Print file header
    echo "${BOLD}${script}${RESET}"
    echo "${DIM}${shebang}${RESET}"
    echo

    # Dispatch to wrapper and process output
    # Check if wrapper can be executed by the target binary by examining its shebang
    local wrapper_shebang
    wrapper_shebang=$(head -1 "$wrapper")
    local wrapper_binary
    wrapper_binary=$(parse_shebang "$wrapper_shebang")

    if [[ "${wrapper_binary##*/}" == "${binary##*/}" ]] || \
       [[ "$wrapper_binary" == "$binary" ]]; then
        # Wrapper is written in the target language - invoke with target binary
        process_output "$lexer" "${blocks[@]}" < <("$binary" "$wrapper" -- "${blocks[@]}" 2>&1)
    else
        # Wrapper is a different language (e.g., bash wrapper for SQL)
        process_output "$lexer" "${blocks[@]}" < <("$wrapper" -- "${blocks[@]}" 2>&1)
    fi
}

main "$@"
