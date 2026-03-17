#!/usr/bin/env bash
#
# run.sh — Run CGC prephase for a single package
#
# Indexes the target directory with CGC, then runs the auto prephase
# to produce scope.json for cartographer exploration.
#
# Usage:
#   ./run.sh /path/to/package
#   ./run.sh .                    # current directory
#   PROVIDER=cursor ./run.sh /path/to/package   # use Cursor CLI
#
# Output:
#   cartographer/prephase/slices.json
#   cartographer/prephase/scopes/<slug>/scope.json
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPHASE_DIR="$SCRIPT_DIR/prephase"
PROMPT_FILE="$PREPHASE_DIR/AUTO_PROMPT.md"
MCP_CONFIG="$PREPHASE_DIR/mcp.json"

PROVIDER="${PROVIDER:-claude}"

TARGET="${1:-.}"
TARGET="$(cd "$TARGET" && pwd)"

# --- Provider setup ---

case "$PROVIDER" in
    claude)
        CLI_CMD="${CLAUDE_CMD:-claude}"
        ;;
    cursor)
        CLI_CMD="${CURSOR_CMD:-agent}"
        ;;
    *)
        echo "Error: unsupported provider '$PROVIDER' for prephase"
        echo "Supported: claude, cursor"
        exit 1
        ;;
esac

# --- Check prerequisites ---

if ! command -v cgc &>/dev/null; then
    echo "Error: cgc not found. Install: pip install codegraphcontext kuzu"
    exit 1
fi

if ! command -v "$CLI_CMD" &>/dev/null; then
    echo "Error: $CLI_CMD not found."
    if [[ "$PROVIDER" = "claude" ]]; then
        echo "Install: npm install -g @anthropic-ai/claude-code"
    else
        echo "Install Cursor CLI: https://cursor.com/cli"
    fi
    exit 1
fi

for f in "$PROMPT_FILE" "$MCP_CONFIG"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: $(basename "$f") not found at $f"
        echo "Run ./update.sh first to copy prompts from cartographer source."
        exit 1
    fi
done

# --- Index with CGC ---

echo "Indexing $TARGET with CGC..."
cgc index "$TARGET"
echo ""
cgc list
echo ""

# --- Run auto prephase ---

LOG_FILE="$SCRIPT_DIR/prephase.log"

echo "Running auto prephase ($PROVIDER + MCP)..."
echo "  Provider: $PROVIDER ($CLI_CMD)"
echo "  Target:   $TARGET"
echo "  Log:      $LOG_FILE"
echo ""

if [[ "$PROVIDER" = "cursor" ]]; then
    # Cursor auto-discovers MCP from .cursor/mcp.json in project hierarchy.
    # Set up config in the target directory so cursor finds it.
    CURSOR_MCP_DIR="$TARGET/.cursor"
    mkdir -p "$CURSOR_MCP_DIR"
    if [[ ! -f "$CURSOR_MCP_DIR/mcp.json" ]]; then
        cp "$MCP_CONFIG" "$CURSOR_MCP_DIR/mcp.json"
        echo "  Installed MCP config at $CURSOR_MCP_DIR/mcp.json"
    fi

    echo "$(cat "$PROMPT_FILE")" | $CLI_CMD -p --yolo --approve-mcps 2>&1 | tee "$LOG_FILE"
else
    claude -p "$(cat "$PROMPT_FILE")" \
        --mcp-config "$MCP_CONFIG" \
        --dangerously-skip-permissions \
        2>&1 | tee "$LOG_FILE"
fi

echo ""
echo "Prephase complete."
echo "Review: cartographer/prephase/slices.json"
echo "Scopes: cartographer/prephase/scopes/*/scope.json"
