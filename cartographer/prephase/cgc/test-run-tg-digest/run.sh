#!/bin/bash
#
# Test run: CGC pre-phase against tg-digest
#
# This runs the CGC auto pre-phase with MCP access to the
# CodeGraphContext graph of /home/dev/project/tg-digest.
#
# Prerequisites:
#   cgc index /home/dev/project/tg-digest  (already done)
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CGC_DIR="$(dirname "$SCRIPT_DIR")"
PROMPT_FILE="$CGC_DIR/AUTO_PROMPT.md"
MCP_CONFIG="$CGC_DIR/mcp.json"
LOG_FILE="$SCRIPT_DIR/auto.log"
SLICES_FILE="$SCRIPT_DIR/slices.json"

if ! command -v cgc &>/dev/null; then
    echo "Error: cgc CLI not found. Install with: pip install codegraphcontext"
    exit 1
fi

if ! cgc list &>/dev/null; then
    echo "Error: No CGC index found. Run: cgc index /home/dev/project/tg-digest"
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: AUTO_PROMPT.md not found at $PROMPT_FILE"
    exit 1
fi

PROMPT=$(cat "$PROMPT_FILE")

# Point the agent at this test run's output directory and the target repo
PROMPT="$PROMPT

## Target Repository

The indexed repository is tg-digest at /home/dev/project/tg-digest.
It is a Go application (53 .go files) for creating Telegram channel digests.

## Output Paths

Write slices.json to: $SLICES_FILE
Write scope files to: $SCRIPT_DIR/scopes/<slug>/scope.json"

echo "CGC Pre-Phase Test Run: tg-digest"
echo "  MCP config: $MCP_CONFIG"
echo "  Output:     $SCRIPT_DIR/"
echo "  Log:        $LOG_FILE"
echo ""

claude -p "$PROMPT" --mcp-config "$MCP_CONFIG" --dangerously-skip-permissions 2>&1 \
    | tee "$LOG_FILE"
