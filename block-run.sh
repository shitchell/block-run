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
       $(basename "$0") [options] <wrapper> <script>

Run a script block-by-block, showing output after each block.
Blocks are separated by blank lines.

Can be used as a shebang:
  #!/path/to/block-run sqlite3

Options:
  --hierarchical       Use '## ' headers to separate blocks instead of blank lines
  --show-block-numbers Show "# Block N" headers before each block
  --help               Show this help message

The interpreter is determined from the shebang line, or from the <wrapper>
argument if provided.

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
    local filename="$2"
    local basename="${binary##*/}"
    local lexer

    case "$basename" in
        python|python3|python2) lexer="python" ;;
        bash|sh|zsh|ksh)        lexer="bash" ;;
        node|nodejs)            lexer="javascript" ;;
        ts-node|tsx)            lexer="typescript" ;;
        mariadb|mysql|sqlite3)  lexer="sql" ;;
        ruby|irb)               lexer="ruby" ;;
        perl)                   lexer="perl" ;;
        php)                    lexer="php" ;;
        lua)                    lexer="lua" ;;
        *)                      lexer="text" ;;
    esac
    
    # If a lexer was not found, try to guess it from the filename
    [[ -z "$lexer" ]] && lexer=$(pygmentize -N "$filename")
    
    echo "$lexer"
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
    local show_numbers="$2"
    shift 2
    local blocks=("$@")

    local marker_regex="^${MARKER}\{([0-9]+)\}${MARKER}$"

    while IFS= read -r line; do
        if [[ "$line" =~ $marker_regex ]]; then
            local idx="${BASH_REMATCH[1]}"
            local block_num=$((idx + 1))

            # Print header (only if enabled)
            if [[ "$show_numbers" == true ]]; then
                echo "${CYAN}# Block ${block_num}${RESET}"
            fi

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
    local wrapper_hint=""
    local split_mode="blank_lines"
    local show_block_numbers=false
    local -a positional=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hierarchical)
                split_mode="hierarchical"
                shift
                ;;
            --show-block-numbers)
                show_block_numbers=true
                shift
                ;;
            --help|-h)
                usage 0
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    # Determine wrapper_hint vs script
    if [[ ${#positional[@]} -eq 1 ]]; then
        # block-run script.py
        script="${positional[0]}"
    elif [[ ${#positional[@]} -eq 2 ]]; then
        if [[ -f "${positional[0]}" ]]; then
            # First arg is a file - probably a mistake
            die "multiple scripts specified: ${positional[*]}"
        else
            # block-run sqlite3 script.sql (shebang-style)
            wrapper_hint="${positional[0]}"
            script="${positional[1]}"
        fi
    elif [[ ${#positional[@]} -eq 0 ]]; then
        die "no script specified"
    else
        die "too many arguments: ${positional[*]}"
    fi

    [[ -f "$script" ]] || die "script not found: $script"

    local binary=""
    local wrapper=""
    local shebang=""

    if [[ -n "$wrapper_hint" ]]; then
        # Wrapper specified directly (shebang-style invocation)
        binary="$wrapper_hint"
        if ! wrapper=$(find_wrapper "$wrapper_hint"); then
            die "no wrapper found for: $wrapper_hint"
        fi
        # Use actual shebang if present, otherwise synthetic
        shebang=$(head -1 "$script")
        [[ "$shebang" =~ ^#! ]] || shebang="#!/usr/bin/env $wrapper_hint"
    else
        # Read shebang from script
        shebang=$(head -1 "$script")
        [[ "$shebang" =~ ^#! ]] || die "no shebang found in $script"

        binary=$(parse_shebang "$shebang")
        [[ -n "$binary" ]] || die "could not parse shebang: $shebang"

        if ! wrapper=$(find_wrapper "$binary"); then
            die "no wrapper found for: $binary (basename: ${binary##*/})"
        fi
    fi

    # Read content (skip shebang if present)
    local content
    local first_line
    first_line=$(head -1 "$script")
    if [[ "$first_line" =~ ^#! ]]; then
        content=$(tail -n +2 "$script")
    else
        content=$(cat "$script")
    fi

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
    lexer=$(get_lexer "$binary" "$script")

    # Print file header
    echo "${BOLD}${script}${RESET}"
    echo "${DIM}${shebang}${RESET}"
    echo

    # Dispatch to wrapper and process output
    # If wrapper is written in the same language as the script, invoke via that binary
    # Otherwise (e.g., bash wrapper for SQL), invoke the wrapper directly
    local wrapper_shebang
    wrapper_shebang=$(head -1 "$wrapper")
    local wrapper_binary
    wrapper_binary=$(parse_shebang "$wrapper_shebang")

    local -a invocation=()
    [[ "${wrapper_binary##*/}" == "${binary##*/}" || "$wrapper_binary" == "$binary" ]] \
        && [[ -z "$wrapper_hint" ]] \
        && invocation+=("$binary")
    invocation+=("$wrapper")

    process_output "$lexer" "$show_block_numbers" "${blocks[@]}" < <("${invocation[@]}" -- "${blocks[@]}" 2>&1)
}

main "$@"
