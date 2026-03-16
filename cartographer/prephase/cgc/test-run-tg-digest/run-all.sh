#!/bin/bash
#
# run-all.sh — Run parallel cartographer explorations
#
# Creates isolated directory trees for each slice, symlinks tg-digest
# source files in, copies explore.sh + PROMPT.md, then runs --init
# and the exploration loop for each scope in parallel.
#
# Usage:
#   ./cartographer/prephase/cgc/test-run-tg-digest/run-all.sh
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARTOGRAPHER_DIR="$(cd "$SCRIPT_DIR/../../../" && pwd)"
TG_DIGEST="/home/dev/project/tg-digest"
RUNS_DIR="$SCRIPT_DIR/runs"
SCOPES_DIR="$SCRIPT_DIR/scopes"

# Cartographer agent model — haiku by default
EXPLORE_MODEL="${EXPLORE_MODEL:-haiku}"

# Read slugs from scopes directory
SLUGS=()
for dir in "$SCOPES_DIR"/*/; do
    [ -d "$dir" ] && SLUGS+=("$(basename "$dir")")
done

if [ ${#SLUGS[@]} -eq 0 ]; then
    echo "Error: no scopes found in $SCOPES_DIR"
    exit 1
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}    PARALLEL CARTOGRAPHER — ${#SLUGS[@]} SLICES OF tg-digest       ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Model:${NC} $EXPLORE_MODEL"
echo ""

# ── Step 1: Set up directory trees ──────────────────────────

rm -rf "$RUNS_DIR"

for slug in "${SLUGS[@]}"; do
    echo -e "${BLUE}Setting up:${NC} $slug"

    RUN_ROOT="$RUNS_DIR/$slug"
    RUN_CARTO="$RUN_ROOT/cartographer"

    # Create cartographer directory structure
    mkdir -p "$RUN_CARTO/exploration"
    mkdir -p "$RUN_CARTO/logs"

    # Symlink tg-digest source directories into the run root
    # so that paths like "internal/storage/storage.go" resolve
    for dir in "$TG_DIGEST"/*/; do
        dirname=$(basename "$dir")
        ln -s "$dir" "$RUN_ROOT/$dirname"
    done

    # Also symlink top-level files (go.mod etc) in case agent reads them
    for f in "$TG_DIGEST"/*.go "$TG_DIGEST"/go.mod "$TG_DIGEST"/go.sum; do
        [ -f "$f" ] && ln -s "$f" "$RUN_ROOT/$(basename "$f")"
    done

    # Copy explore.sh
    cp "$CARTOGRAPHER_DIR/explore.sh" "$RUN_CARTO/explore.sh"
    chmod +x "$RUN_CARTO/explore.sh"

    # Generate PROMPT.md with absolute paths
    # claude -p resolves paths from git root, not cwd — so we must
    # replace relative cartographer/exploration/ with the absolute path
    ABS_EXPLORATION="$RUN_CARTO/exploration"
    sed "s|cartographer/exploration/|$ABS_EXPLORATION/|g" \
        "$CARTOGRAPHER_DIR/PROMPT.md" > "$RUN_CARTO/PROMPT.md"

    # Copy scope.json into exploration/
    cp "$SCOPES_DIR/$slug/scope.json" "$RUN_CARTO/exploration/scope.json"

    echo -e "  ${GREEN}✓${NC} $RUN_ROOT"
done

echo ""

# ── Step 2: Run --init for each ─────────────────────────────

echo -e "${BLUE}Initializing all ${#SLUGS[@]} explorations...${NC}"
echo ""

for slug in "${SLUGS[@]}"; do
    RUN_CARTO="$RUNS_DIR/$slug/cartographer"
    echo -e "${YELLOW}--init:${NC} $slug"
    "$RUN_CARTO/explore.sh" --init 2>&1 | tail -4
    echo ""
done

# ── Step 3: Launch all in parallel ──────────────────────────

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Launching ${#SLUGS[@]} cartographers in parallel (model: $EXPLORE_MODEL)...${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

PIDS=()

for slug in "${SLUGS[@]}"; do
    RUN_CARTO="$RUNS_DIR/$slug/cartographer"
    LOG="$RUNS_DIR/$slug/explore.log"

    echo -e "${BLUE}Starting:${NC} $slug → $LOG"

    CLAUDE_MODEL="$EXPLORE_MODEL" "$RUN_CARTO/explore.sh" > "$LOG" 2>&1 &
    PIDS+=($!)
done

echo ""
echo -e "${YELLOW}Waiting for all ${#SLUGS[@]} to finish...${NC}"
echo -e "PIDs: ${PIDS[*]}"
echo ""

# Wait and report
FAILED=0
for i in "${!SLUGS[@]}"; do
    slug="${SLUGS[$i]}"
    pid="${PIDS[$i]}"

    if wait "$pid"; then
        EXPLORED=$(wc -l < "$RUNS_DIR/$slug/cartographer/exploration/queue_explored.txt" 2>/dev/null | tr -d ' ')
        TOTAL=$(wc -l < "$RUNS_DIR/$slug/cartographer/exploration/queue_all.txt" 2>/dev/null | tr -d ' ')
        echo -e "${GREEN}✓${NC} $slug — $EXPLORED/$TOTAL files explored"
    else
        echo -e "${RED}✗${NC} $slug — FAILED (check runs/$slug/explore.log)"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}All ${#SLUGS[@]} explorations complete. (model: $EXPLORE_MODEL)${NC}"
else
    echo -e "${YELLOW}$FAILED / ${#SLUGS[@]} explorations failed. (model: $EXPLORE_MODEL)${NC}"
fi
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Results in: $RUNS_DIR/<slug>/cartographer/exploration/"
echo ""
