#!/usr/bin/env bash
#
# run.sh — Cartographer v2 full pipeline orchestrator
#
# Runs the complete cartographer pipeline:
#   CGC index → Opus prephase → Sonnet wave planning → Sonnet exploration
#   → Sonnet synthesis → Opus cross-scope synthesis
#
# Usage:
#   ./cartographer/run.sh /path/to/source/root              # full generation
#   ./cartographer/run.sh /path/to/source/root --incremental  # incremental update
#
# Environment:
#   PROVIDER=claude|cursor       Provider for all agents (default: claude)
#   CLAUDE_MODEL=sonnet          Exploration/synthesis model (default: sonnet)
#   CROSS_MODEL=opus             Cross-scope model (default: opus)
#   SKIP_PREPHASE=1              Skip prephase (use existing scopes)
#   SKIP_CROSS=1                 Skip cross-scope synthesis
#   SCOPE=<slug>                 Only process this scope (for debugging)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPHASE_DIR="$SCRIPT_DIR/prephase/cgc"
SCOPES_DIR="$SCRIPT_DIR/prephase/scopes"

SOURCE_ROOT="${1:-}"
INCREMENTAL=false
[[ "${2:-}" = "--incremental" ]] && INCREMENTAL=true

if [[ -z "$SOURCE_ROOT" ]]; then
    echo "Usage: ./cartographer/run.sh /path/to/source/root [--incremental]"
    exit 1
fi
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"

# ============================================================
# Colors
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$INCREMENTAL" = true ]]; then
    echo -e "${GREEN}          CARTOGRAPHER v2 — INCREMENTAL PIPELINE               ${NC}"
else
    echo -e "${GREEN}          CARTOGRAPHER v2 — FULL PIPELINE                      ${NC}"
fi
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}Source:${NC}    $SOURCE_ROOT"
echo -e "${BLUE}Provider:${NC}  ${PROVIDER:-claude}"
echo -e "${BLUE}Models:${NC}    explore=${CLAUDE_MODEL:-sonnet}, synth=${SYNTH_MODEL:-sonnet}, cross=${CROSS_MODEL:-opus}"
echo ""

# ============================================================
# Step 1: CGC Index
# ============================================================

echo -e "${CYAN}Step 1: CGC Index${NC}"

if command -v cgc &>/dev/null; then
    echo "  Indexing $SOURCE_ROOT..."
    cgc index "$SOURCE_ROOT" 2>&1 | head -5
    echo "  Done."
else
    echo "  Warning: cgc not found. Skipping CGC indexing."
    echo "  Wave planning will work without graph data."
fi
echo ""

# ============================================================
# Step 2: Prephase (Opus scoping)
# ============================================================

if [[ "${SKIP_PREPHASE:-}" != "1" ]] && [[ "$INCREMENTAL" = false ]]; then
    echo -e "${CYAN}Step 2: Prephase (Opus scoping)${NC}"

    if [[ -f "$PREPHASE_DIR/auto.sh" ]]; then
        bash "$PREPHASE_DIR/auto.sh"
        echo ""
    else
        echo "  Warning: auto.sh not found. Skipping prephase."
        echo "  Ensure scope files exist in $SCOPES_DIR/"
    fi
else
    echo -e "${CYAN}Step 2: Prephase — skipped${NC}"
fi
echo ""

# ============================================================
# Step 3-6: Per-scope pipeline (parallel)
# ============================================================

# Collect scope directories
SCOPE_DIRS=()
if [[ -n "${SCOPE:-}" ]]; then
    # Single scope mode
    if [[ -d "$SCOPES_DIR/$SCOPE" ]]; then
        SCOPE_DIRS=("$SCOPES_DIR/$SCOPE")
    else
        echo -e "${RED}Error: scope '$SCOPE' not found in $SCOPES_DIR/${NC}"
        exit 1
    fi
elif [[ -d "$SCOPES_DIR" ]]; then
    while IFS= read -r d; do
        # Only include dirs that have a scope.json (directly or in exploration/)
        if [[ -f "$d/scope.json" ]] || [[ -f "$d/cartographer/exploration/scope.json" ]]; then
            SCOPE_DIRS+=("$d")
        fi
    done < <(find "$SCOPES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
fi

# Fallback: check for single-scope mode (scope.json directly in exploration/)
if [[ ${#SCOPE_DIRS[@]} -eq 0 ]] && [[ -f "$SCRIPT_DIR/exploration/scope.json" ]]; then
    echo -e "${YELLOW}No scopes in prephase/scopes/. Using single-scope mode.${NC}"
    SCOPE_DIRS=("__single__")
fi

if [[ ${#SCOPE_DIRS[@]} -eq 0 ]]; then
    echo -e "${RED}Error: no scopes found. Run prephase first or place scope.json in exploration/.${NC}"
    exit 1
fi

echo -e "${CYAN}Step 3-6: Per-scope exploration + synthesis (${#SCOPE_DIRS[@]} scopes)${NC}"
echo ""

PIDS=()
SCOPE_NAMES=()

for scope_dir in "${SCOPE_DIRS[@]}"; do

    if [[ "$scope_dir" = "__single__" ]]; then
        SCOPE_NAME="single"
        SCOPE_EXPLORATION="$SCRIPT_DIR/exploration"
    else
        SCOPE_NAME=$(basename "$scope_dir")

        # Determine exploration dir for this scope
        if [[ -f "$scope_dir/cartographer/exploration/scope.json" ]]; then
            SCOPE_EXPLORATION="$scope_dir/cartographer/exploration"
        elif [[ -f "$scope_dir/scope.json" ]]; then
            # Scope.json is at root — set up exploration dir
            SCOPE_EXPLORATION="$scope_dir/exploration"
            mkdir -p "$SCOPE_EXPLORATION"
            if [[ ! -f "$SCOPE_EXPLORATION/scope.json" ]]; then
                cp "$scope_dir/scope.json" "$SCOPE_EXPLORATION/scope.json"
            fi
        else
            echo -e "${YELLOW}  Skipping $SCOPE_NAME — no scope.json found${NC}"
            continue
        fi
    fi

    echo -e "${BLUE}  Processing scope: $SCOPE_NAME${NC}"
    SCOPE_NAMES+=("$SCOPE_NAME")

    (
        export EXPLORATION_DIR="$SCOPE_EXPLORATION"
        export PROJECT_ROOT="$SOURCE_ROOT"

        # Step 3: Init + wave planning + exploration
        if [[ "$INCREMENTAL" = true ]]; then
            bash "$SCRIPT_DIR/explore.sh" --incremental 2>&1 | \
                sed "s/^/  [$SCOPE_NAME] /"
        else
            bash "$SCRIPT_DIR/explore.sh" --init 2>&1 | \
                sed "s/^/  [$SCOPE_NAME] /"
            bash "$SCRIPT_DIR/explore.sh" 2>&1 | \
                sed "s/^/  [$SCOPE_NAME] /"
        fi

        # Step 5: Per-scope synthesis
        if [[ "$INCREMENTAL" = true ]]; then
            bash "$SCRIPT_DIR/synthesize.sh" --incremental "$SOURCE_ROOT" 2>&1 | \
                sed "s/^/  [$SCOPE_NAME] /"
        else
            bash "$SCRIPT_DIR/synthesize.sh" "$SOURCE_ROOT" 2>&1 | \
                sed "s/^/  [$SCOPE_NAME] /"
        fi
    ) &

    PIDS+=($!)
done

# Wait for all scopes to complete
echo ""
echo -e "${CYAN}  Waiting for ${#PIDS[@]} scope(s) to complete...${NC}"

FAILED=0
for idx in "${!PIDS[@]}"; do
    if wait "${PIDS[$idx]}"; then
        echo -e "${GREEN}  Scope ${SCOPE_NAMES[$idx]}: done${NC}"
    else
        echo -e "${RED}  Scope ${SCOPE_NAMES[$idx]}: FAILED${NC}"
        FAILED=$((FAILED + 1))
    fi
done

echo ""

if [[ $FAILED -gt 0 ]]; then
    echo -e "${YELLOW}Warning: $FAILED scope(s) failed. Cross-scope synthesis may be incomplete.${NC}"
fi

# ============================================================
# Step 7: Cross-scope synthesis (Opus)
# ============================================================

if [[ "${SKIP_CROSS:-}" != "1" ]] && [[ ${#SCOPE_NAMES[@]} -gt 1 ]]; then
    echo -e "${CYAN}Step 7: Cross-scope synthesis (Opus)${NC}"
    bash "$SCRIPT_DIR/cross-synthesize.sh" "$SOURCE_ROOT"
    echo ""
elif [[ ${#SCOPE_NAMES[@]} -le 1 ]]; then
    echo -e "${CYAN}Step 7: Cross-scope synthesis — skipped (single scope)${NC}"
else
    echo -e "${CYAN}Step 7: Cross-scope synthesis — skipped (SKIP_CROSS=1)${NC}"
fi

# ============================================================
# Final report
# ============================================================

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}              CARTOGRAPHER v2 PIPELINE COMPLETE                 ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Scopes processed:  ${#SCOPE_NAMES[@]}"
echo -e "  Failed:            $FAILED"
echo ""
echo -e "  Per-scope output:"
for name in "${SCOPE_NAMES[@]}"; do
    echo -e "    - $name/"
done
echo ""
if [[ -f "$SCRIPT_DIR/exploration/architecture.md" ]]; then
    echo -e "  Cross-scope:       $SCRIPT_DIR/exploration/architecture.md"
fi
echo ""
