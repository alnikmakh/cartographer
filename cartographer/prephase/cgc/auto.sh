#!/bin/bash
#
# auto.sh — Non-interactive pre-phase using CGC graph
#
# Runs the auto pre-phase prompt with MCP access to a CodeGraphContext
# dependency graph, producing slices.json and scope files without
# user interaction.
#
# Usage:
#   ./cartographer/prephase/cgc/auto.sh
#
# Prerequisites:
#   Run cgc/setup.sh <repo-path> first to index the codebase.
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/AUTO_PROMPT.md"
MCP_CONFIG="$SCRIPT_DIR/mcp.json"
LOG_FILE="$SCRIPT_DIR/auto.log"

# Check cgc is installed
if ! command -v cgc &>/dev/null; then
    echo "Error: cgc CLI not found. Install with: pip install codegraphcontext"
    exit 1
fi

# Verify index exists
if ! cgc list &>/dev/null; then
    echo "Error: No CGC index found. Run cgc/setup.sh <repo-path> first."
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: AUTO_PROMPT.md not found at $PROMPT_FILE"
    exit 1
fi

if [ ! -f "$MCP_CONFIG" ]; then
    echo "Error: mcp.json not found at $MCP_CONFIG"
    exit 1
fi

PROMPT=$(cat "$PROMPT_FILE")

echo "Running auto pre-phase (CGC graph mode)..."
echo "  MCP config: $MCP_CONFIG"
echo "  Log:        $LOG_FILE"
echo ""

claude -p "$PROMPT" --mcp-config "$MCP_CONFIG" --dangerously-skip-permissions 2>&1 \
    | tee "$LOG_FILE"
