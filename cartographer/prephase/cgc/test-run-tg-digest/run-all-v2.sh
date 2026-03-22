#!/bin/bash
#
# run-all-v2.sh — Full v2 pipeline: prephase → wave exploration → synthesis
#
# Complete pipeline:
#   1. CGC index
#   2. Opus prephase (scope determination via CGC graph)
#   3. Sonnet wave planning + exploration (parallel per scope)
#   4. Sonnet per-scope synthesis (parallel)
#   5. Opus cross-scope synthesis → architecture.md
#
# Usage:
#   ./run-all-v2.sh                           # Full run (prephase + explore + synthesize)
#   ./run-all-v2.sh --skip-prephase           # Reuse existing scopes
#   ./run-all-v2.sh --explore-only            # Just exploration, no synthesis
#   ./run-all-v2.sh --synthesize-only         # Just synthesis (requires prior exploration)
#   ./run-all-v2.sh --incremental             # Re-explore only changed files
#   EXPLORE_MODEL=sonnet ./run-all-v2.sh      # Override exploration model
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARTOGRAPHER_DIR="$(cd "$SCRIPT_DIR/../../../" && pwd)"
PREPHASE_DIR="$(cd "$SCRIPT_DIR/../../" && pwd)"
TG_DIGEST="/home/dev/project/tg-digest"
RUNS_DIR="$SCRIPT_DIR/runs"

# Models — v2 defaults
EXPLORE_MODEL="${EXPLORE_MODEL:-sonnet}"
SYNTH_MODEL="${SYNTH_MODEL:-sonnet}"
CROSS_MODEL="${CROSS_MODEL:-opus}"
PROVIDER="${PROVIDER:-claude}"

# Mode flags
EXPLORE=true
SYNTHESIZE=true
INCREMENTAL=false
RUN_PREPHASE=true

case "${1:-}" in
    --explore-only)    SYNTHESIZE=false; RUN_PREPHASE=false ;;
    --synthesize-only) EXPLORE=false; RUN_PREPHASE=false ;;
    --incremental)     INCREMENTAL=true; RUN_PREPHASE=false ;;
    --skip-prephase)   RUN_PREPHASE=false ;;
esac

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}    CARTOGRAPHER v2 — FULL PIPELINE (tg-digest)                ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Explore model:${NC}  $EXPLORE_MODEL"
echo -e "${BLUE}  Synth model:${NC}    $SYNTH_MODEL"
echo -e "${BLUE}  Cross model:${NC}    $CROSS_MODEL"
echo -e "${BLUE}  Provider:${NC}       $PROVIDER"
echo -e "${BLUE}  Prephase:${NC}       $RUN_PREPHASE"
echo -e "${BLUE}  Incremental:${NC}    $INCREMENTAL"
echo ""

# ── Step 1: CGC Index ─────────────────────────────────────────

echo -e "${CYAN}Step 1: CGC Index${NC}"
if command -v cgc &>/dev/null; then
    echo "  Indexing $TG_DIGEST..."
    cgc index "$TG_DIGEST" 2>&1 | tail -3 || true
    echo "  Done."
else
    echo "  Warning: cgc not found. Wave planning will work without graph data."
fi
echo ""

# ── Step 2: Prephase (Opus scope determination) ──────────────

# Prephase writes to cartographer/prephase/scopes/<slug>/scope.json
# (auto.sh uses claude -p which resolves from git root)
PREPHASE_SCOPES_DIR="$PREPHASE_DIR/scopes"

if [[ "$RUN_PREPHASE" = true ]]; then
    echo -e "${CYAN}Step 2: Prephase — Opus scope determination via CGC graph${NC}"

    # Clean old prephase output
    rm -rf "$PREPHASE_SCOPES_DIR"
    rm -f "$PREPHASE_DIR/slices.json"

    # Run auto.sh (writes scopes via claude agent)
    AUTO_SH="$SCRIPT_DIR/../auto.sh"
    if [[ -f "$AUTO_SH" ]]; then
        echo "  Running auto.sh (Opus + CGC MCP)..."
        bash "$AUTO_SH" 2>&1 | tail -20
        echo ""

        # Verify scopes were created
        if [[ -d "$PREPHASE_SCOPES_DIR" ]]; then
            SCOPE_COUNT=$(find "$PREPHASE_SCOPES_DIR" -name "scope.json" | wc -l | tr -d ' ')
            echo -e "  ${GREEN}Prephase created $SCOPE_COUNT scopes${NC}"
        else
            echo -e "  ${RED}Error: prephase did not create any scopes${NC}"
            echo "  Expected output at: $PREPHASE_SCOPES_DIR/"
            exit 1
        fi
    else
        echo -e "  ${RED}Error: auto.sh not found at $AUTO_SH${NC}"
        exit 1
    fi
    echo ""

    # Copy fresh scopes to test-run-tg-digest/scopes/ for archival
    rm -rf "$SCRIPT_DIR/scopes"
    cp -r "$PREPHASE_SCOPES_DIR" "$SCRIPT_DIR/scopes"
    echo "  Archived scopes to $SCRIPT_DIR/scopes/"
    echo ""
else
    echo -e "${CYAN}Step 2: Prephase — skipped (using existing scopes)${NC}"
    echo ""
fi

# Determine scopes directory — prefer prephase output, fall back to local copy
if [[ -d "$PREPHASE_SCOPES_DIR" ]] && [[ -n "$(ls "$PREPHASE_SCOPES_DIR" 2>/dev/null)" ]]; then
    SCOPES_DIR="$PREPHASE_SCOPES_DIR"
elif [[ -d "$SCRIPT_DIR/scopes" ]]; then
    SCOPES_DIR="$SCRIPT_DIR/scopes"
else
    echo -e "${RED}Error: no scopes found${NC}"
    exit 1
fi

# Read slugs from scopes directory
SLUGS=()
for dir in "$SCOPES_DIR"/*/; do
    [ -d "$dir" ] && SLUGS+=("$(basename "$dir")")
done

if [ ${#SLUGS[@]} -eq 0 ]; then
    echo "Error: no scopes found in $SCOPES_DIR"
    exit 1
fi

echo -e "${BLUE}  Scopes (${#SLUGS[@]}):${NC} ${SLUGS[*]}"
echo ""

# ── Step 3: Set up directory trees ────────────────────────────

echo -e "${CYAN}Step 3: Setting up run directories${NC}"

if [[ "$INCREMENTAL" = false ]] && [[ "$EXPLORE" = true ]]; then
    rm -rf "$RUNS_DIR"
fi

for slug in "${SLUGS[@]}"; do
    RUN_ROOT="$RUNS_DIR/$slug"
    EXPLORATION="$RUN_ROOT/cartographer/exploration"

    # Create directory structure
    mkdir -p "$EXPLORATION/nodes" "$EXPLORATION/edges"
    mkdir -p "$RUN_ROOT/cartographer/logs"

    # Symlink tg-digest source directories (if not already linked)
    for dir in "$TG_DIGEST"/*/; do
        dirname=$(basename "$dir")
        [ -L "$RUN_ROOT/$dirname" ] || [ -d "$RUN_ROOT/$dirname" ] || ln -s "$dir" "$RUN_ROOT/$dirname"
    done

    # Symlink top-level files
    for f in "$TG_DIGEST"/*.go "$TG_DIGEST"/go.mod "$TG_DIGEST"/go.sum; do
        [ -f "$f" ] && { [ -L "$RUN_ROOT/$(basename "$f")" ] || ln -s "$f" "$RUN_ROOT/$(basename "$f")"; }
    done

    # Copy scope.json into exploration/
    if [[ ! -f "$EXPLORATION/scope.json" ]] || [[ "$INCREMENTAL" = false ]]; then
        cp "$SCOPES_DIR/$slug/scope.json" "$EXPLORATION/scope.json"
    fi

    echo -e "  ${GREEN}+${NC} $slug"
done
echo ""

# ── Step 4: Explore (parallel) ────────────────────────────────

if [[ "$EXPLORE" = true ]]; then
    echo -e "${CYAN}Step 4: Wave Exploration (parallel, model: $EXPLORE_MODEL)${NC}"
    echo ""

    PIDS=()

    for slug in "${SLUGS[@]}"; do
        RUN_ROOT="$RUNS_DIR/$slug"
        EXPLORATION="$RUN_ROOT/cartographer/exploration"
        LOG="$RUN_ROOT/explore.log"

        echo -e "${BLUE}Starting:${NC} $slug → $LOG"

        (
            export EXPLORATION_DIR="$EXPLORATION"
            export PROJECT_ROOT="$RUN_ROOT"
            export SOURCE_ROOT="$TG_DIGEST"
            export CLAUDE_MODEL="$EXPLORE_MODEL"
            export PROVIDER="$PROVIDER"

            if [[ "$INCREMENTAL" = true ]]; then
                bash "$CARTOGRAPHER_DIR/explore.sh" --incremental
            else
                bash "$CARTOGRAPHER_DIR/explore.sh" --init
                bash "$CARTOGRAPHER_DIR/explore.sh"
            fi
        ) > "$LOG" 2>&1 &

        PIDS+=($!)
    done

    echo ""
    echo -e "${YELLOW}Waiting for ${#SLUGS[@]} explorations...${NC}"
    echo ""

    EXPLORE_FAILED=0
    for i in "${!SLUGS[@]}"; do
        slug="${SLUGS[$i]}"
        pid="${PIDS[$i]}"

        if wait "$pid"; then
            EXPLORED=$(wc -l < "$RUNS_DIR/$slug/cartographer/exploration/queue_explored.txt" 2>/dev/null | tr -d ' ')
            TOTAL=$(wc -l < "$RUNS_DIR/$slug/cartographer/exploration/queue_all.txt" 2>/dev/null | tr -d ' ')
            NODES=$(ls "$RUNS_DIR/$slug/cartographer/exploration/nodes/"*.json 2>/dev/null | wc -l | tr -d ' ')
            echo -e "${GREEN}+${NC} $slug — $EXPLORED/$TOTAL files, $NODES nodes"
        else
            echo -e "${RED}x${NC} $slug — FAILED (check runs/$slug/explore.log)"
            EXPLORE_FAILED=$((EXPLORE_FAILED + 1))
        fi
    done

    echo ""
    if [ "$EXPLORE_FAILED" -gt 0 ]; then
        echo -e "${YELLOW}Warning: $EXPLORE_FAILED / ${#SLUGS[@]} explorations failed.${NC}"
    else
        echo -e "${GREEN}All ${#SLUGS[@]} explorations complete.${NC}"
    fi
    echo ""
fi

# ── Step 5: Per-scope synthesis (parallel) ────────────────────

if [[ "$SYNTHESIZE" = true ]]; then
    echo -e "${CYAN}Step 5: Per-scope Synthesis (parallel, model: $SYNTH_MODEL)${NC}"
    echo ""

    PIDS=()
    SYNTH_SLUGS=()

    for slug in "${SLUGS[@]}"; do
        EXPLORATION="$RUNS_DIR/$slug/cartographer/exploration"

        # Skip scopes with no nodes
        if [[ -z "$(ls "$EXPLORATION/nodes/"*.json 2>/dev/null)" ]]; then
            echo -e "${YELLOW}Skip:${NC} $slug (no nodes)"
            continue
        fi

        LOG="$RUNS_DIR/$slug/synthesis.log"
        echo -e "${BLUE}Starting:${NC} $slug → $LOG"

        (
            export EXPLORATION_DIR="$EXPLORATION"
            export SYNTH_MODEL="$SYNTH_MODEL"
            export PROVIDER="$PROVIDER"

            if [[ "$INCREMENTAL" = true ]]; then
                bash "$CARTOGRAPHER_DIR/synthesize.sh" --incremental "$TG_DIGEST"
            else
                bash "$CARTOGRAPHER_DIR/synthesize.sh" "$TG_DIGEST"
            fi
        ) > "$LOG" 2>&1 &

        PIDS+=($!)
        SYNTH_SLUGS+=("$slug")
    done

    echo ""
    echo -e "${YELLOW}Waiting for ${#SYNTH_SLUGS[@]} syntheses...${NC}"
    echo ""

    SYNTH_FAILED=0
    for i in "${!SYNTH_SLUGS[@]}"; do
        slug="${SYNTH_SLUGS[$i]}"
        pid="${PIDS[$i]}"

        if wait "$pid"; then
            findings="$RUNS_DIR/$slug/cartographer/exploration/findings.md"
            manifest="$RUNS_DIR/$slug/cartographer/exploration/scope-manifest.json"
            lines=$(wc -l < "$findings" 2>/dev/null | tr -d ' ')
            has_manifest=$([[ -f "$manifest" ]] && echo "yes" || echo "no")
            echo -e "${GREEN}+${NC} $slug — findings: $lines lines, manifest: $has_manifest"
        else
            echo -e "${RED}x${NC} $slug — FAILED (check runs/$slug/synthesis.log)"
            SYNTH_FAILED=$((SYNTH_FAILED + 1))
        fi
    done

    echo ""
    if [ "$SYNTH_FAILED" -gt 0 ]; then
        echo -e "${YELLOW}Warning: $SYNTH_FAILED / ${#SYNTH_SLUGS[@]} syntheses failed.${NC}"
    else
        echo -e "${GREEN}All ${#SYNTH_SLUGS[@]} syntheses complete.${NC}"
    fi
    echo ""

    # ── Step 6: Cross-scope synthesis ─────────────────────────

    # Count manifests
    MANIFEST_COUNT=0
    for slug in "${SLUGS[@]}"; do
        [[ -f "$RUNS_DIR/$slug/cartographer/exploration/scope-manifest.json" ]] && MANIFEST_COUNT=$((MANIFEST_COUNT + 1))
    done

    if [[ $MANIFEST_COUNT -gt 1 ]]; then
        echo -e "${CYAN}Step 6: Cross-scope Synthesis (Opus)${NC}"
        echo ""

        # Collect manifests and findings for cross-scope prompt
        CROSS_LOG="$RUNS_DIR/cross-synthesis.log"

        # The cross-synthesize.sh expects manifests in a specific location.
        # Create a consolidated exploration dir with all manifests + findings.
        CROSS_DIR="$RUNS_DIR/_cross_scope"
        mkdir -p "$CROSS_DIR"

        # Build cross-scope prompt directly since cross-synthesize.sh
        # searches prephase/scopes/ which doesn't match our runs/ layout
        CROSS_PROMPT_FILE=$(mktemp)
        CROSS_OUTPUT="$RUNS_DIR/architecture.md"

        MANIFESTS_SECTION=""
        FINDINGS_SECTION=""

        for slug in "${SLUGS[@]}"; do
            manifest="$RUNS_DIR/$slug/cartographer/exploration/scope-manifest.json"
            findings="$RUNS_DIR/$slug/cartographer/exploration/findings.md"

            if [[ -f "$manifest" ]] && [[ -f "$findings" ]]; then
                MANIFESTS_SECTION="$MANIFESTS_SECTION
### Scope: $slug

\`\`\`json
$(cat "$manifest")
\`\`\`
"
                FINDINGS_SECTION="$FINDINGS_SECTION
### Scope: $slug

$(cat "$findings")

---
"
            fi
        done

        # CGC cross-scope edges
        CGC_CROSS=""
        if command -v cgc &>/dev/null; then
            CGC_CROSS=$(cgc analyze deps "$TG_DIGEST" 2>/dev/null || echo '{}')
        fi

        cat > "$CROSS_PROMPT_FILE" <<CROSS_EOF
$(cat "$CARTOGRAPHER_DIR/CROSS_SCOPE_PROMPT.md")

---

## Scope Manifests

$MANIFESTS_SECTION

## Scope Findings

$FINDINGS_SECTION

## CGC Cross-Scope Graph

\`\`\`json
$CGC_CROSS
\`\`\`
CROSS_EOF

        echo "  Running Opus cross-scope synthesis..."

        claude -p \
            --model "$CROSS_MODEL" \
            --output-format text \
            --tools "Read" \
            --add-dir "$TG_DIGEST" \
            --allowedTools "Read" \
            < "$CROSS_PROMPT_FILE" > "$CROSS_OUTPUT" 2>"$CROSS_LOG" || true

        rm -f "$CROSS_PROMPT_FILE"

        if [[ -f "$CROSS_OUTPUT" ]] && [[ -s "$CROSS_OUTPUT" ]]; then
            CROSS_LINES=$(wc -l < "$CROSS_OUTPUT")
            echo -e "${GREEN}  architecture.md: $CROSS_LINES lines → $CROSS_OUTPUT${NC}"
        else
            echo -e "${RED}  Cross-scope synthesis failed (check $CROSS_LOG)${NC}"
        fi
        echo ""
    else
        echo -e "${YELLOW}Step 6: Cross-scope synthesis skipped ($MANIFEST_COUNT manifests)${NC}"
        echo ""
    fi
fi

# ── Summary ───────────────────────────────────────────────────

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}              CARTOGRAPHER v2 TEST RUN COMPLETE                 ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

printf "%-25s %6s %6s %6s %10s %8s\n" "SCOPE" "FILES" "NODES" "EDGES" "FINDINGS" "MANIFEST"
printf "%-25s %6s %6s %6s %10s %8s\n" "-----" "-----" "-----" "-----" "--------" "--------"

for slug in "${SLUGS[@]}"; do
    exp="$RUNS_DIR/$slug/cartographer/exploration"
    files=$(wc -l < "$exp/queue_all.txt" 2>/dev/null | tr -d ' ')
    nodes=$(ls "$exp/nodes/"*.json 2>/dev/null | wc -l | tr -d ' ')
    edges=$(ls "$exp/edges/"*.json 2>/dev/null | wc -l | tr -d ' ')
    findings_lines=$([[ -f "$exp/findings.md" ]] && wc -l < "$exp/findings.md" | tr -d ' ' || echo "0")
    has_manifest=$([[ -f "$exp/scope-manifest.json" ]] && echo "yes" || echo "no")

    printf "%-25s %6s %6s %6s %10s %8s\n" "$slug" "$files" "$nodes" "$edges" "${findings_lines}L" "$has_manifest"
done

echo ""
if [[ -f "$RUNS_DIR/architecture.md" ]]; then
    echo -e "Cross-scope: $RUNS_DIR/architecture.md ($(wc -l < "$RUNS_DIR/architecture.md" | tr -d ' ') lines)"
fi
echo ""
echo "Results in: $RUNS_DIR/"
echo ""
