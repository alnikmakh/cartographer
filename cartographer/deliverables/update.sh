#!/usr/bin/env bash
#
# update.sh — Copy deliverables from cartographer source
#
# Copies only the files needed to run the full pipeline on any codebase.
# Run this after making changes to prompts/scripts in cartographer/.
#
# Usage:
#   ./cartographer/deliverables/update.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARTO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Updating deliverables from $CARTO_DIR ..."

# --- Exploration ---
cp "$CARTO_DIR/explore.sh"          "$SCRIPT_DIR/explore.sh"
cp "$CARTO_DIR/PROMPT.md"           "$SCRIPT_DIR/PROMPT.md"

# --- Synthesis ---
cp "$CARTO_DIR/SYNTHESIS_PROMPT.md" "$SCRIPT_DIR/SYNTHESIS_PROMPT.md"

# --- CGC prephase ---
mkdir -p "$SCRIPT_DIR/prephase"
cp "$CARTO_DIR/prephase/cgc/AUTO_PROMPT.md" "$SCRIPT_DIR/prephase/AUTO_PROMPT.md"
cp "$CARTO_DIR/prephase/cgc/PROMPT.md"      "$SCRIPT_DIR/prephase/PROMPT.md"
cp "$CARTO_DIR/prephase/cgc/mcp.json"       "$SCRIPT_DIR/prephase/mcp.json"

chmod +x "$SCRIPT_DIR/explore.sh"
chmod +x "$SCRIPT_DIR/run.sh"
chmod +x "$SCRIPT_DIR/synthesize.sh"

echo ""
echo "Updated:"
echo "  explore.sh          — exploration loop"
echo "  PROMPT.md           — exploration agent prompt"
echo "  SYNTHESIS_PROMPT.md — synthesis agent prompt"
echo "  prephase/AUTO_PROMPT.md — CGC auto prephase prompt"
echo "  prephase/PROMPT.md      — CGC interactive prephase prompt"
echo "  prephase/mcp.json       — MCP config for CGC"
echo ""
echo "Not updated (local scripts):"
echo "  run.sh              — prephase runner"
echo "  synthesize.sh       — synthesis runner"
echo "  README.md           — docs"
