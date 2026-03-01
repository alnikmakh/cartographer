#!/bin/bash
#
# Run the scout loop for each tg-digest feature context.
# Swaps CONTEXT.md, resets QUEUE.md and OVERVIEW.md, runs the loop,
# then saves the result to scout/results/.
#
# Usage:
#   ./run-scout-all.sh                    # Claude, unlimited
#   ./run-scout-all.sh 30                 # Claude, max 30 iterations per feature
#   ./run-scout-all.sh codex 30           # Codex, max 30 iterations per feature
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXTS_DIR="$SCRIPT_DIR/scout/contexts"
RESULTS_DIR="$SCRIPT_DIR/scout/results"
TEMPLATES_DIR="$SCRIPT_DIR/scout/templates"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$RESULTS_DIR"

# Validate templates exist
for f in "$TEMPLATES_DIR/QUEUE.md" "$TEMPLATES_DIR/OVERVIEW.md"; do
    if [ ! -f "$f" ]; then
        echo -e "${RED}Missing template: $f${NC}"
        exit 1
    fi
done

# Collect context files
CONTEXT_FILES=("$CONTEXTS_DIR"/*.md)
TOTAL=${#CONTEXT_FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo -e "${RED}No context files found in $CONTEXTS_DIR${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}              SCOUT ALL FEATURES ($TOTAL contexts)              ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

COMPLETED=0
FAILED=0

for ctx in "${CONTEXT_FILES[@]}"; do
    name=$(basename "$ctx" .md)
    COMPLETED=$((COMPLETED + 1))

    echo ""
    echo -e "${CYAN}[$COMPLETED/$TOTAL] ─── $name ───${NC}"
    echo ""

    # Check if result already exists (resume support)
    if [ -f "$RESULTS_DIR/${name}-OVERVIEW.md" ]; then
        echo -e "${YELLOW}  Result already exists, skipping. Delete to re-run.${NC}"
        continue
    fi

    # Swap context, reset queue and overview
    cp "$ctx" "$SCRIPT_DIR/scout/CONTEXT.md"
    cp "$TEMPLATES_DIR/QUEUE.md" "$SCRIPT_DIR/scout/QUEUE.md"
    cp "$TEMPLATES_DIR/OVERVIEW.md" "$SCRIPT_DIR/scout/OVERVIEW.md"

    # Run the scout loop, forwarding all arguments
    if "$SCRIPT_DIR/run-scout.sh" "$@"; then
        cp "$SCRIPT_DIR/scout/OVERVIEW.md" "$RESULTS_DIR/${name}-OVERVIEW.md"
        cp "$SCRIPT_DIR/scout/QUEUE.md" "$RESULTS_DIR/${name}-QUEUE.md"
        echo -e "${GREEN}  Saved: scout/results/${name}-OVERVIEW.md${NC}"
    else
        echo -e "${RED}  Scout loop failed for $name${NC}"
        FAILED=$((FAILED + 1))
        # Save partial results anyway
        cp "$SCRIPT_DIR/scout/OVERVIEW.md" "$RESULTS_DIR/${name}-OVERVIEW.partial.md"
        cp "$SCRIPT_DIR/scout/QUEUE.md" "$RESULTS_DIR/${name}-QUEUE.partial.md"
    fi
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  DONE: $((COMPLETED - FAILED))/$TOTAL succeeded, $FAILED failed${NC}"
echo -e "${GREEN}  Results in: scout/results/                                    ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
