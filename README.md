# block-run

Execute code files block-by-block, like a Jupyter notebook. Each block is syntax-highlighted, executed, and its output displayed before moving to the next block. Context (variables, state) is preserved across blocks.

## Purpose

This tool is primarily designed as a **teaching and learning aid**. It helps instructors walk through code step-by-step during lessons, and helps learners see exactly how each piece of code builds on the previous one. By showing code and output together in digestible chunks, it makes it easier to understand how programs flow and how state evolves.

## Example Output

Given a script like this:

```python
#!/usr/bin/env python3

# Block 1: Define some data
name = "Alice"
scores = [85, 92, 78, 96]
print(f"Student: {name}")

# Block 2: Calculate statistics
average = sum(scores) / len(scores)
print(f"Average score: {average:.1f}")

# Block 3: Determine grade
if average >= 90:
    grade = "A"
elif average >= 80:
    grade = "B"
else:
    grade = "C"
print(f"Final grade: {grade}")
```

Running `block-run script.py` produces:

```
script.py
#!/usr/bin/env python3

# Block 1: Define some data
name = "Alice"
scores = [85, 92, 78, 96]
print(f"Student: {name}")
─────────────────────────────────────────
Student: Alice

# Block 2: Calculate statistics
average = sum(scores) / len(scores)
print(f"Average score: {average:.1f}")
─────────────────────────────────────────
Average score: 87.8

# Block 3: Determine grade
if average >= 90:
    grade = "A"
elif average >= 80:
    grade = "B"
else:
    grade = "C"
print(f"Final grade: {grade}")
─────────────────────────────────────────
Final grade: B
```

Notice how variables like `scores` and `average` carry over between blocks, just like in a Jupyter notebook.

## Installation

```bash
# Clone the repo
git clone https://github.com/shitchell/block-run.git
cd block-run

# Install globally (requires root)
sudo ./install.sh

# Or install locally (to ~/.local/bin, ~/.local/share, ~/.config)
./install.sh --local
```

To uninstall:

```bash
# Remove local install (always runs)
./uninstall.sh

# Remove both local and global install
sudo ./uninstall.sh
```

## Usage

```bash
block-run script.py       # Run Python file block by block
block-run script.sh       # Run Bash file block by block
block-run script.js       # Run Node.js file block by block
```

## How It Works

1. Reads the shebang to determine the interpreter
2. Splits the file into blocks (separated by blank lines, or `## ` headers with `--hierarchical`)
3. For each block:
   - Shows syntax-highlighted code
   - Executes with context from all previous blocks
   - Displays only the current block's output

## Writing Scripts

Blocks are separated by **blank lines** (one or more empty lines).

### Python Example

```python
#!/usr/bin/env python3

# Block 1: Define data
x = 10
print(f"x = {x}")

# Block 2: Use previous variable
y = x * 2
print(f"y = {y}")
```

## Supported Languages

| Wrapper | Symlinks |
|---------|----------|
| `python3` | `python` |
| `bash` | `sh` |
| `node` | `nodejs` |

## Directory Structure

block-run follows the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).

### Wrapper Search Paths (in order)

| Priority | Path | Description |
|----------|------|-------------|
| 1 | `$XDG_DATA_HOME/block-run/wrappers/` | User wrappers (default: `~/.local/share/block-run/wrappers/`) |
| 2 | `/usr/local/share/block-run/wrappers/` | System wrappers |

### Config Search Paths (in order)

| Priority | Path | Description |
|----------|------|-------------|
| 1 | `$XDG_CONFIG_HOME/block-run/config` | User config (default: `~/.config/block-run/config`) |
| 2 | `/etc/block-run/config` | System config |

User paths take precedence, allowing you to override system wrappers with your own.

---

# Adding New Language Wrappers

To add support for a new language, create a wrapper script in one of the wrapper directories above.

## Wrapper Interface

The wrapper receives arguments in this format:

```
wrapper --binary <path-to-interpreter> -- 'block1' 'block2' 'block3' ...
```

- `--binary <path>`: The full path to the interpreter (from the shebang)
- `--`: Separates options from blocks
- Remaining args: Each block as a separate quoted string

## Wrapper Responsibilities

1. Parse `--binary` to know which interpreter to use
2. Execute blocks sequentially, preserving state between them
3. For each block:
   - Print the block with syntax highlighting (use `pygmentize` if available)
   - Execute the block
   - Print only the *new* output (not output from previous blocks)
   - Print a separator line

## Example: Minimal Wrapper Template

```bash
#!/usr/bin/env bash
set -euo pipefail

BINARY=""
BLOCKS=()

# Colors
CYAN=$'\e[36m'
DIM=$'\e[2m'
RESET=$'\e[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)
            BINARY="$2"
            shift 2
            ;;
        --)
            shift
            BLOCKS=("$@")
            break
            ;;
        *)
            shift
            ;;
    esac
done

# Syntax highlight if available
highlight() {
    if command -v pygmentize &>/dev/null; then
        pygmentize -l <language>
    else
        cat
    fi
}

separator() {
    echo "${DIM}─────────────────────────────────────────${RESET}"
}

# Process blocks
block_num=0
for block in "${BLOCKS[@]}"; do
    ((++block_num))

    # Show block header + highlighted code
    echo "${CYAN}-- Block $block_num${RESET}"
    echo "$block" | highlight
    separator

    # Execute block and capture output
    # (implementation depends on language)

    echo
done
```

## State Preservation Strategies

Different languages need different approaches:

### Interpreted with REPL (Python, Node)
- Start interpreter as coprocess or use heredoc
- Feed blocks one at a time
- Capture output between blocks

### Shell (Bash)
- Source blocks into current environment
- Variables persist naturally

## Config File (Optional)

Create a config file at one of the config search paths (see [Directory Structure](#directory-structure)) to map interpreter paths to wrapper names:

```
/usr/local/bin/custom-python=python3
```

Format: `<binary-path>=<wrapper-name>`

This is useful when you have a custom interpreter path that doesn't match a wrapper name (e.g., a custom-built Python at `/opt/python312/bin/python`).

## Testing Your Wrapper

```bash
# Test directly
./wrappers/mywrapper --binary /usr/bin/interpreter -- 'print("block 1")' 'print("block 2")'

# Test via block-run
echo -e '#!/usr/bin/interpreter\n\nblock1\n\nblock2' > test.script
block-run test.script
```
