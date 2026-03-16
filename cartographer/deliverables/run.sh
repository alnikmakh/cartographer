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

TARGET="${1:-.}"
TARGET="$(cd "$TARGET" && pwd)"

# --- Check prerequisites ---

if ! command -v cgc &>/dev/null; then
    echo "Error: cgc not found. Install: pip install codegraphcontext kuzu"
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "Error: claude CLI not found. Install: npm install -g @anthropic-ai/claude-code"
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

echo "Running auto prephase (Opus + MCP)..."
echo "  Target:  $TARGET"
echo "  Log:     $LOG_FILE"
echo ""

claude -p "$(cat "$PROMPT_FILE")" \
    --mcp-config "$MCP_CONFIG" \
    --dangerously-skip-permissions \
    2>&1 | tee "$LOG_FILE"

echo ""
echo "Prephase complete."
echo "Review: cartographer/prephase/slices.json"
echo "Scopes: cartographer/prephase/scopes/*/scope.json"
