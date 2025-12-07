// block-run: Execute code files block-by-block, like a notebook.
//
// Blocks are separated by blank lines. Each block is passed to a
// language-specific wrapper which handles syntax highlighting and execution.
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"
)

var (
	wrapperDirs []string
	configFiles []string
)

func init() {
	// XDG defaults
	xdgDataHome := os.Getenv("XDG_DATA_HOME")
	if xdgDataHome == "" {
		home, _ := os.UserHomeDir()
		xdgDataHome = filepath.Join(home, ".local", "share")
	}

	xdgConfigHome := os.Getenv("XDG_CONFIG_HOME")
	if xdgConfigHome == "" {
		home, _ := os.UserHomeDir()
		xdgConfigHome = filepath.Join(home, ".config")
	}

	// Platform-specific paths
	if runtime.GOOS == "windows" {
		programData := os.Getenv("PROGRAMDATA")
		if programData == "" {
			programData = "C:/ProgramData"
		}
		wrapperDirs = []string{
			filepath.Join(xdgDataHome, "block-run", "wrappers"),
			filepath.Join(programData, "block-run", "wrappers"),
		}
		configFiles = []string{
			filepath.Join(xdgConfigHome, "block-run", "config"),
			filepath.Join(programData, "block-run", "config"),
		}
	} else {
		wrapperDirs = []string{
			filepath.Join(xdgDataHome, "block-run", "wrappers"),
			"/usr/local/share/block-run/wrappers",
		}
		configFiles = []string{
			filepath.Join(xdgConfigHome, "block-run", "config"),
			"/etc/block-run/config",
		}
	}
}

func die(msg string) {
	fmt.Fprintf(os.Stderr, "error: %s\n", msg)
	os.Exit(1)
}

func usage() {
	fmt.Printf(`Usage: block-run [options] <script>

Run a script block-by-block, showing output after each block.
Blocks are separated by blank lines.

Options:
  --hierarchical    Use '## ' headers to separate blocks instead of blank lines
  --help, -h        Show this help message

The interpreter is determined from the shebang line.

Wrapper search paths:
`)
	for _, d := range wrapperDirs {
		fmt.Printf("  - %s\n", d)
	}
	fmt.Println("\nConfig search paths:")
	for _, f := range configFiles {
		fmt.Printf("  - %s\n", f)
	}
}

// parseShebang extracts the binary path from a shebang line.
// Handles: #!/path/to/bin, #!/usr/bin/env bin, #!/path/to/bin args
func parseShebang(shebang string) string {
	// Remove #! prefix and trim
	shebang = strings.TrimPrefix(shebang, "#!")
	shebang = strings.TrimSpace(shebang)

	if shebang == "" {
		return ""
	}

	// Handle /usr/bin/env case
	envRe := regexp.MustCompile(`^/usr/bin/env\s+(\S+)`)
	if matches := envRe.FindStringSubmatch(shebang); len(matches) > 1 {
		cmd := matches[1]
		// Try to resolve to full path
		if resolved, err := exec.LookPath(cmd); err == nil {
			return resolved
		}
		return cmd
	}

	// Direct path - extract just the binary (first word)
	parts := strings.Fields(shebang)
	if len(parts) > 0 {
		return parts[0]
	}
	return ""
}

// findWrapper finds the wrapper for a given binary.
func findWrapper(binary string) string {
	basename := filepath.Base(binary)
	wrapperName := ""

	// Check config files for exact path match
	for _, configFile := range configFiles {
		if data, err := os.ReadFile(configFile); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				if strings.HasPrefix(line, binary+"=") {
					wrapperName = strings.TrimPrefix(line, binary+"=")
					wrapperName = strings.TrimSpace(wrapperName)
					break
				}
			}
		}
		if wrapperName != "" {
			break
		}
	}

	// Default to basename if no config match
	if wrapperName == "" {
		wrapperName = basename
	}

	// Search wrapper directories
	for _, wrapperDir := range wrapperDirs {
		wrapperPath := filepath.Join(wrapperDir, wrapperName)
		if info, err := os.Stat(wrapperPath); err == nil && !info.IsDir() {
			// Check if executable
			if info.Mode()&0111 != 0 {
				return wrapperPath
			}
		}
	}

	return ""
}

// splitBlocksBlankLines splits content into blocks separated by blank lines.
func splitBlocksBlankLines(content string) []string {
	var blocks []string
	var currentBlock []string

	scanner := bufio.NewScanner(strings.NewReader(content))
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "" {
			// Empty line - end current block if we have one
			if len(currentBlock) > 0 {
				blocks = append(blocks, strings.Join(currentBlock, "\n"))
				currentBlock = nil
			}
		} else {
			currentBlock = append(currentBlock, line)
		}
	}

	// Don't forget the last block
	if len(currentBlock) > 0 {
		blocks = append(blocks, strings.Join(currentBlock, "\n"))
	}

	return blocks
}

// splitBlocksHierarchical splits content into blocks separated by ## headers.
func splitBlocksHierarchical(content string) []string {
	var blocks []string
	var currentBlock []string

	scanner := bufio.NewScanner(strings.NewReader(content))
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "## ") {
			// Header line - start new block
			if len(currentBlock) > 0 {
				blocks = append(blocks, strings.Join(currentBlock, "\n"))
			}
			currentBlock = []string{line}
		} else {
			if len(currentBlock) > 0 || strings.TrimSpace(line) != "" {
				currentBlock = append(currentBlock, line)
			}
		}
	}

	// Don't forget the last block
	if len(currentBlock) > 0 {
		blocks = append(blocks, strings.Join(currentBlock, "\n"))
	}

	return blocks
}

func main() {
	// Parse arguments
	var scriptPath string
	hierarchical := false

	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--help", "-h":
			usage()
			os.Exit(0)
		case "--hierarchical":
			hierarchical = true
		default:
			if strings.HasPrefix(args[i], "-") {
				die(fmt.Sprintf("unknown option: %s", args[i]))
			}
			if scriptPath != "" {
				die("multiple scripts specified")
			}
			scriptPath = args[i]
		}
	}

	if scriptPath == "" {
		die("no script specified")
	}

	// Read the script
	content, err := os.ReadFile(scriptPath)
	if err != nil {
		die(fmt.Sprintf("could not read script: %v", err))
	}

	lines := strings.Split(string(content), "\n")
	if len(lines) == 0 {
		die("script is empty")
	}

	// Parse shebang
	shebang := lines[0]
	if !strings.HasPrefix(shebang, "#!") {
		die(fmt.Sprintf("no shebang found in %s", scriptPath))
	}

	binary := parseShebang(shebang)
	if binary == "" {
		die(fmt.Sprintf("could not parse shebang: %s", shebang))
	}

	// Find wrapper
	wrapper := findWrapper(binary)
	if wrapper == "" {
		die(fmt.Sprintf("no wrapper found for: %s (basename: %s)", binary, filepath.Base(binary)))
	}

	// Split into blocks (skip shebang line)
	contentWithoutShebang := strings.Join(lines[1:], "\n")

	var blocks []string
	if hierarchical {
		blocks = splitBlocksHierarchical(contentWithoutShebang)
	} else {
		blocks = splitBlocksBlankLines(contentWithoutShebang)
	}

	if len(blocks) == 0 {
		die("no blocks found in script")
	}

	// Build wrapper arguments
	wrapperArgs := []string{wrapper, "--binary", binary, "--"}
	wrapperArgs = append(wrapperArgs, blocks...)

	// Execute wrapper, replacing current process
	if err := syscall.Exec(wrapper, wrapperArgs, os.Environ()); err != nil {
		die(fmt.Sprintf("could not execute wrapper: %v", err))
	}
}
