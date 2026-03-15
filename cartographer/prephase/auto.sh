#!/bin/bash
#
# auto.sh — Non-interactive pre-phase
#
# Runs the auto pre-phase prompt against a repomix structural output,
# producing slices.json and individual scope files without user interaction.
#
# Usage:
#   ./cartographer/prephase/auto.sh <structure.xml>
#   ./cartographer/prephase/auto.sh cartographer/prephase/structure.xml
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/AUTO_PROMPT.md"
LOG_FILE="$SCRIPT_DIR/auto.log"

STRUCTURE="${1:?Usage: auto.sh <structure.xml>}"

if [ ! -f "$STRUCTURE" ]; then
    echo "Error: structure file not found: $STRUCTURE"
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: AUTO_PROMPT.md not found at $PROMPT_FILE"
    exit 1
fi

PROMPT=$(cat "$PROMPT_FILE")

echo "Running auto pre-phase..."
echo "  Structure: $STRUCTURE"
echo "  Log:       $LOG_FILE"
echo ""

claude -p "$PROMPT

Analyze: $STRUCTURE" --dangerously-skip-permissions 2>&1 \
    | tee "$LOG_FILE"
