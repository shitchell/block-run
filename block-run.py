#!/usr/bin/env python3
"""
block-run: Execute code files block-by-block, like a notebook.

Blocks are separated by blank lines. Each block is passed to a
language-specific wrapper which handles execution. This script handles
syntax highlighting and output formatting.
"""

import os
import re
import sys
import shutil
import argparse
import subprocess
from pathlib import Path
from typing import Optional


# XDG defaults
XDG_DATA_HOME = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
XDG_CONFIG_HOME = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))

# Search paths (user first, then system)
if sys.platform == "win32":
    WRAPPER_DIRS = [
        XDG_DATA_HOME / "block-run" / "wrappers",
        Path(os.environ.get("PROGRAMDATA", "C:/ProgramData")) / "block-run" / "wrappers",
    ]
    CONFIG_FILES = [
        XDG_CONFIG_HOME / "block-run" / "config",
        Path(os.environ.get("PROGRAMDATA", "C:/ProgramData")) / "block-run" / "config",
    ]
else:
    WRAPPER_DIRS = [
        XDG_DATA_HOME / "block-run" / "wrappers",
        Path("/usr/local/share/block-run/wrappers"),
    ]
    CONFIG_FILES = [
        XDG_CONFIG_HOME / "block-run" / "config",
        Path("/etc/block-run/config"),
    ]

# Marker character for chunk display protocol (ASCII Group Separator)
MARKER = "\x1d"

# Colors
BOLD = "\033[1m"
CYAN = "\033[36m"
DIM = "\033[2m"
RESET = "\033[0m"

# Lexer mappings for syntax highlighting
LEXER_MAP = {
    "python": "python",
    "python3": "python",
    "python2": "python",
    "bash": "bash",
    "sh": "bash",
    "zsh": "bash",
    "ksh": "bash",
    "node": "javascript",
    "nodejs": "javascript",
    "ts-node": "typescript",
    "tsx": "typescript",
    "mariadb": "sql",
    "mysql": "sql",
    "sqlite3": "sql",
    "ruby": "ruby",
    "irb": "ruby",
    "perl": "perl",
    "php": "php",
    "lua": "lua",
}


def die(msg: str) -> None:
    """Print error and exit."""
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def parse_shebang(shebang: str) -> Optional[str]:
    """
    Extract binary path from shebang line.

    Handles:
      - #!/path/to/bin
      - #!/usr/bin/env bin
      - #!/path/to/bin args
    """
    # Remove #! prefix and strip
    shebang = shebang.lstrip("#!").strip()

    if not shebang:
        return None

    # Handle /usr/bin/env case
    env_match = re.match(r"^/usr/bin/env\s+(\S+)", shebang)
    if env_match:
        cmd = env_match.group(1)
        # Try to resolve to full path
        resolved = shutil.which(cmd)
        return resolved if resolved else cmd

    # Direct path - extract just the binary (first word)
    return shebang.split()[0]


def find_wrapper(binary: str) -> Optional[Path]:
    """
    Find wrapper for a given binary.

    Search order:
      1. Config files for exact path match
      2. Wrapper directories for basename match
    """
    basename = Path(binary).name
    wrapper_name = None

    # Check config files for exact path match
    for config_file in CONFIG_FILES:
        if config_file.is_file():
            try:
                for line in config_file.read_text().splitlines():
                    if line.startswith(f"{binary}="):
                        wrapper_name = line.split("=", 1)[1].strip()
                        break
            except (IOError, OSError):
                pass
        if wrapper_name:
            break

    # Default to basename if no config match
    if not wrapper_name:
        wrapper_name = basename

    # Search wrapper directories
    for wrapper_dir in WRAPPER_DIRS:
        wrapper_path = wrapper_dir / wrapper_name
        if wrapper_path.is_file() and os.access(wrapper_path, os.X_OK):
            return wrapper_path

    return None


def get_lexer(binary: str, filename: str) -> str:
    """Map binary basename to pygmentize lexer."""
    basename = Path(binary).name
    lexer = LEXER_MAP.get(basename, "")

    # If no lexer found, try to guess from filename
    if not lexer and shutil.which("pygmentize"):
        try:
            result = subprocess.run(
                ["pygmentize", "-N", filename],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                lexer = result.stdout.strip()
        except (subprocess.SubprocessError, OSError):
            pass

    return lexer or "text"


def highlight(code: str, lexer: str) -> str:
    """Syntax highlight code using pygmentize if available."""
    if lexer == "text" or not shutil.which("pygmentize"):
        return code

    try:
        result = subprocess.run(
            ["pygmentize", "-l", lexer],
            input=code,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return result.stdout.rstrip("\n")
    except (subprocess.SubprocessError, OSError):
        pass

    return code


def separator() -> str:
    """Return separator line."""
    return f"{DIM}─────────────────────────────────────────{RESET}"


def split_blocks_blank_lines(content: str) -> list[str]:
    """Split content into blocks separated by blank lines."""
    blocks = []
    current_block = []

    for line in content.splitlines():
        if not line.strip():
            # Empty line - end current block if we have one
            if current_block:
                blocks.append("\n".join(current_block))
                current_block = []
        else:
            current_block.append(line)

    # Don't forget the last block
    if current_block:
        blocks.append("\n".join(current_block))

    return blocks


def split_blocks_hierarchical(content: str) -> list[str]:
    """Split content into blocks separated by ## headers."""
    blocks = []
    current_block = []

    for line in content.splitlines():
        if line.startswith("## "):
            # Header line - start new block
            if current_block:
                blocks.append("\n".join(current_block))
            current_block = [line]
        else:
            if current_block or line.strip():
                current_block.append(line)

    # Don't forget the last block
    if current_block:
        blocks.append("\n".join(current_block))

    return blocks


def process_output(
    output: str,
    blocks: list[str],
    lexer: str,
    show_block_numbers: bool,
) -> None:
    """Process wrapper output, replacing markers with highlighted code."""
    marker_pattern = re.compile(rf"^{re.escape(MARKER)}\{{(\d+)\}}{re.escape(MARKER)}$")

    # Use split('\n') instead of splitlines() because splitlines() treats
    # the \x1d marker character as a line separator
    for line in output.split("\n"):
        match = marker_pattern.match(line)
        if match:
            idx = int(match.group(1))
            block_num = idx + 1

            # Print header (only if enabled)
            if show_block_numbers:
                print(f"{CYAN}# Block {block_num}{RESET}")

            # Print highlighted code
            print(highlight(blocks[idx], lexer))

            # Print separator
            print(separator())
        else:
            # Pass through as-is
            print(line)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run a script block-by-block, showing output after each block.",
        epilog=f"""
Wrapper search paths:
  {chr(10).join(f'  - {d}' for d in WRAPPER_DIRS)}

Config search paths:
  {chr(10).join(f'  - {f}' for f in CONFIG_FILES)}
""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "script",
        help="Script file to run",
    )
    parser.add_argument(
        "--hierarchical",
        action="store_true",
        help="Use '## ' headers to separate blocks instead of blank lines",
    )
    parser.add_argument(
        "--show-block-numbers",
        action="store_true",
        help='Show "# Block N" headers before each block',
    )

    args = parser.parse_args()

    script_path = Path(args.script)

    if not script_path.is_file():
        die(f"script not found: {args.script}")

    # Read the script
    try:
        content = script_path.read_text()
    except (IOError, OSError) as e:
        die(f"could not read script: {e}")

    lines = content.splitlines()
    if not lines:
        die("script is empty")

    # Parse shebang
    shebang = lines[0]
    if not shebang.startswith("#!"):
        die(f"no shebang found in {args.script}")

    binary = parse_shebang(shebang)
    if not binary:
        die(f"could not parse shebang: {shebang}")

    # Find wrapper
    wrapper = find_wrapper(binary)
    if not wrapper:
        die(f"no wrapper found for: {binary} (basename: {Path(binary).name})")

    # Split into blocks (skip shebang line)
    content_without_shebang = "\n".join(lines[1:])

    if args.hierarchical:
        blocks = split_blocks_hierarchical(content_without_shebang)
    else:
        blocks = split_blocks_blank_lines(content_without_shebang)

    if not blocks:
        die("no blocks found in script")

    # Get lexer for syntax highlighting
    lexer = get_lexer(binary, args.script)

    # Print file header
    print(f"{BOLD}{args.script}{RESET}")
    print(f"{DIM}{shebang}{RESET}")
    print()

    # Execute wrapper and process output
    wrapper_args = [str(wrapper), "--binary", binary, "--"] + blocks

    try:
        result = subprocess.run(
            wrapper_args,
            capture_output=True,
            text=True,
        )
        output = result.stdout + result.stderr
    except (subprocess.SubprocessError, OSError) as e:
        die(f"failed to run wrapper: {e}")

    process_output(output, blocks, lexer, args.show_block_numbers)


if __name__ == "__main__":
    main()
