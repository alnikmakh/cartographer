#!/bin/bash
#
# Scout Loop — Layer-based discovery/proving loop
#
# Architecture:
#   layer=0, frontier=entry point functions
#   LOOP:
#     DISCOVER: read frontier files, trace ONLY listed functions → write QUEUE.md
#     PROVE (repeat): classify edges until unchecked == 0 → write QUEUE.md
#     ADVANCE (bash):
#       explored = source file:line from ALL edges in QUEUE.md
#       targets = target file:line function() from RELEVANT edges in QUEUE.md
#       next = targets whose file:line is not in explored
#       next empty? → done
#       layer >= max_depth? → done
#       else → write next to FRONTIER.md, layer++, continue
#
# Neither agent touches FRONTIER.md. Bash owns layers.
#
# Usage:
#   ./run-scout.sh                        # Claude, unlimited
#   ./run-scout.sh 40                     # Claude, max 40 iterations
#   ./run-scout.sh codex 40               # Codex, max 40 iterations
#   ./run-scout.sh gemini 40              # Gemini, max 40 iterations
#   ./run-scout.sh copilot 40             # Copilot, max 40 iterations
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Provider setup ---

PROVIDER="claude"
MAX_ITERATIONS=0

# Parse arguments
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    MAX_ITERATIONS="$1"
elif [[ -n "${1:-}" ]]; then
    PROVIDER="$1"
    if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$2"
    fi
fi

case "$PROVIDER" in
    claude)
        CLI_CMD="${CLAUDE_CMD:-claude}"
        CLI_FLAGS="-p --dangerously-skip-permissions"
        [ -n "${CLAUDE_MODEL:-}" ] && CLI_FLAGS="$CLI_FLAGS --model $CLAUDE_MODEL"
        PIPE_MODE="stdin"
        ;;
    codex)
        CLI_CMD="${CODEX_CMD:-codex}"
        CLI_FLAGS="exec --dangerously-bypass-approvals-and-sandbox -"
        PIPE_MODE="stdin"
        ;;
    gemini)
        CLI_CMD="${GEMINI_CMD:-gemini}"
        MODEL="${GEMINI_MODEL:-gemini-3.1-pro-preview}"
        CLI_FLAGS="-m $MODEL --yolo -p \"\""
        PIPE_MODE="stdin"
        ;;
    copilot)
        CLI_CMD="copilot"
        CLI_FLAGS="--allow-all-tools"
        PIPE_MODE="arg"
        ;;
    *)
        echo "Unknown provider: $PROVIDER"
        echo "Supported: claude, codex, gemini, copilot"
        exit 1
        ;;
esac

if ! command -v "$CLI_CMD" &> /dev/null; then
    echo "Error: $CLI_CMD not found"
    exit 1
fi

# --- Colors ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Paths ---

QUEUE="$SCRIPT_DIR/scout/QUEUE.md"
FRONTIER="$SCRIPT_DIR/scout/FRONTIER.md"
CONTEXT="$SCRIPT_DIR/scout/CONTEXT.md"
DISCOVER_PROMPT="$SCRIPT_DIR/scout/PROMPT_discover.md"
PROVE_PROMPT="$SCRIPT_DIR/scout/PROMPT_prove.md"
LOG_DIR="$SCRIPT_DIR/logs"

mkdir -p "$LOG_DIR"

# --- Validate files ---

for f in "$QUEUE" "$DISCOVER_PROMPT" "$PROVE_PROMPT" \
         "$CONTEXT" "$FRONTIER" \
         "$SCRIPT_DIR/.specify/memory/constitution.md"; do
    if [ ! -f "$f" ]; then
        echo -e "${RED}Error: $(basename "$f") not found at $f${NC}"
        exit 1
    fi
done

# --- Functions ---

count_unchecked() {
    grep -c '^\- \[ \]' "$QUEUE" 2>/dev/null || true
}

count_proven() {
    grep -c '^\- \[x\]' "$QUEUE" 2>/dev/null || true
}

count_irrelevant() {
    awk '/^## Irrelevant/{found=1; next} /^## /{found=0} found && /^- /{count++} END{print count+0}' "$QUEUE"
}

frontier_has_files() {
    # Check if ## Explore section in FRONTIER.md has any non-empty lines
    # Uses grep after extracting the section (mawk doesn't support exit-from-rule)
    local explore_lines
    explore_lines=$(awk '/^## Explore/{found=1; next} /^## /{found=0} found{print}' "$FRONTIER")
    echo "$explore_lines" | grep -q '\S'
}

extract_entry_point_functions() {
    # Parse CONTEXT.md ## Entry Points, extract file:line function() refs
    local refs=""
    local edges=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local fileline func
        fileline=$(echo "$line" | grep -oP '\S+:\d+')
        func=$(echo "$line" | grep -oP '— \K\S+')
        if [ -n "$fileline" ] && [ -n "$func" ]; then
            refs+="$fileline $func"$'\n'
            edges+="- [ ] [d0] BOUNDARY → $fileline $func — entry_point"$'\n'
        fi
    done < <(awk '/^## Entry Points/{found=1; next} /^## /{found=0} found && /^- /{print}' "$CONTEXT")

    refs=$(echo "$refs" | sed '/^\s*$/d' | sort -u)
    edges=$(echo "$edges" | sed '/^\s*$/d')

    {
        echo "## Layer"
        echo "0"
        echo ""
        echo "## Explore"
        echo "$refs"
    } > "$FRONTIER"

    # Seed QUEUE.md with entry-point edges for proving
    if [ -n "$edges" ] && ! grep -q 'BOUNDARY →' "$QUEUE"; then
        local tmp
        tmp=$(mktemp)
        EDGES_BLOCK="$edges" awk '/^edge_type:/{print; print ""; print ENVIRON["EDGES_BLOCK"]; next} {print}' "$QUEUE" > "$tmp"
        mv "$tmp" "$QUEUE"
    fi
}

compute_next_frontier() {
    local layer="$1"

    # Explored: file:line from source side of ALL edges
    # e.g. "client.go:23" from "- [x] [d0] client.go:23 NewClient() → ..."
    local explored
    explored=$(grep -E '^\- \[[ x]\]' "$QUEUE" \
        | grep -oP '\[d\d+\]\s+\K\S+' \
        | sort -u) || true

    # Merge cumulative frontier entries (ALL_VISITED) — tracks every file:line
    # that has ever been on a frontier, even if it produced no edges (dead ends)
    explored=$(printf '%s\n%s' "$explored" "$ALL_VISITED" | sed '/^\s*$/d' | sort -u)

    # Targets: full reference from target side of RELEVANT edges
    # e.g. "session.go:10 FileSessionStorage{}" from "... → session.go:10 FileSessionStorage{} — DI"
    # Lazy .+? stops at first " — " (edge_type separator)
    local target_refs
    target_refs=$(grep -E '^\- \[x\]' "$QUEUE" \
        | grep -oP '→\s+\K.+?(?=\s+—)' \
        | sort -u) || true

    # Filter: keep targets whose file:line is not in explored
    local next=""
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        local fileline="${ref%% *}"  # "session.go:10 Foo()" → "session.go:10"
        if ! echo "$explored" | grep -qxF "$fileline"; then
            next+="$ref"$'\n'
        fi
    done <<< "$target_refs"

    next=$(echo "$next" | sed '/^\s*$/d')

    if [ -z "$next" ]; then
        return 1
    fi

    {
        echo "## Layer"
        echo "$layer"
        echo ""
        echo "## Explore"
        echo "$next"
    } > "$FRONTIER"

    return 0
}

run_agent() {
    local prompt_file="$1"
    local log_file="$2"

    if [ "$PIPE_MODE" = "stdin" ]; then
        cat "$prompt_file" | $CLI_CMD $CLI_FLAGS 2>&1 | tee "$log_file"
    elif [ "$PIPE_MODE" = "arg" ]; then
        local prompt_content
        prompt_content=$(cat "$prompt_file")
        $CLI_CMD $CLI_FLAGS -p "$prompt_content" 2>&1 | tee "$log_file"
    fi
}

# --- Session log ---

SESSION_LOG="$LOG_DIR/scout_session_$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "$SESSION_LOG") 2>&1

# --- Phase 1: Initialize frontier from CONTEXT.md entry points ---

extract_entry_point_functions

# --- Banner ---

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}                     SCOUT LOOP STARTING                      ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}Provider:${NC}       $PROVIDER ($CLI_CMD)"
echo -e "${BLUE}Queue:${NC}          scout/QUEUE.md"
[ $MAX_ITERATIONS -gt 0 ] && echo -e "${BLUE}Max iterations:${NC} $MAX_ITERATIONS"
echo -e "${BLUE}Log:${NC}            $SESSION_LOG"
echo ""
echo -e "${CYAN}Layer-based loop: discover → prove → advance${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

# --- Main loop ---

ITERATION=0
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=3
LAYER=0
ALL_VISITED=""  # cumulative file:line entries from all frontiers

while frontier_has_files; do

    # --- Discovery phase ---

    ITERATION=$((ITERATION + 1))
    if [ $MAX_ITERATIONS -gt 0 ] && [ $ITERATION -ge $MAX_ITERATIONS ]; then
        echo -e "${YELLOW}Reached max iterations: $MAX_ITERATIONS${NC}"
        break
    fi

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    UNCHECKED=$(count_unchecked)
    PROVEN=$(count_proven)
    IRRELEVANT=$(count_irrelevant)

    echo ""
    echo -e "${PURPLE}════════════════════ ITERATION $ITERATION (Layer $LAYER) ════════════════════${NC}"
    echo -e "${BLUE}[$TIMESTAMP]${NC}"
    echo -e "  Mode:       ${CYAN}discover${NC}"
    echo -e "  Unchecked:  $UNCHECKED"
    echo -e "  Proven:     $PROVEN"
    echo -e "  Irrelevant: $IRRELEVANT"
    echo ""

    LOG_FILE="$LOG_DIR/scout_discover_iter_${ITERATION}_$(date '+%Y%m%d_%H%M%S').log"

    AGENT_OUTPUT=""
    if AGENT_OUTPUT=$(run_agent "$DISCOVER_PROMPT" "$LOG_FILE"); then
        if echo "$AGENT_OUTPUT" | grep -q "<promise>DONE</promise>"; then
            echo -e "${GREEN}✓ discover completed${NC}"
            CONSECUTIVE_FAILURES=0
        else
            echo -e "${YELLOW}⚠ No completion signal from discovery${NC}"
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
                echo -e "${RED}✗ $MAX_CONSECUTIVE_FAILURES consecutive failures — shutting down.${NC}"
                break
            fi
            tail -5 "$LOG_FILE" 2>/dev/null || true
        fi
    else
        echo -e "${RED}✗ Discovery agent failed${NC}"
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        tail -5 "$LOG_FILE" 2>/dev/null || true
        if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
            echo -e "${RED}✗ $MAX_CONSECUTIVE_FAILURES consecutive failures — shutting down.${NC}"
            break
        fi
    fi

    sleep 2

    # --- Proving phase (drain all unchecked edges) ---

    while [ "$(count_unchecked)" -gt 0 ]; do
        ITERATION=$((ITERATION + 1))
        if [ $MAX_ITERATIONS -gt 0 ] && [ $ITERATION -ge $MAX_ITERATIONS ]; then
            echo -e "${YELLOW}Reached max iterations: $MAX_ITERATIONS${NC}"
            break 2
        fi

        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        UNCHECKED=$(count_unchecked)
        PROVEN=$(count_proven)
        IRRELEVANT=$(count_irrelevant)

        echo ""
        echo -e "${PURPLE}════════════════════ ITERATION $ITERATION (Layer $LAYER) ════════════════════${NC}"
        echo -e "${BLUE}[$TIMESTAMP]${NC}"
        echo -e "  Mode:       ${CYAN}prove${NC}"
        echo -e "  Unchecked:  $UNCHECKED"
        echo -e "  Proven:     $PROVEN"
        echo -e "  Irrelevant: $IRRELEVANT"
        echo ""

        LOG_FILE="$LOG_DIR/scout_prove_iter_${ITERATION}_$(date '+%Y%m%d_%H%M%S').log"

        AGENT_OUTPUT=""
        if AGENT_OUTPUT=$(run_agent "$PROVE_PROMPT" "$LOG_FILE"); then
            if echo "$AGENT_OUTPUT" | grep -q "<promise>DONE</promise>"; then
                echo -e "${GREEN}✓ prove completed${NC}"
                CONSECUTIVE_FAILURES=0
            else
                echo -e "${YELLOW}⚠ No completion signal from proving${NC}"
                CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
                if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
                    echo -e "${RED}✗ $MAX_CONSECUTIVE_FAILURES consecutive failures — shutting down.${NC}"
                    break 2
                fi
                tail -5 "$LOG_FILE" 2>/dev/null || true
            fi
        else
            echo -e "${RED}✗ Proving agent failed${NC}"
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            tail -5 "$LOG_FILE" 2>/dev/null || true
            if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
                echo -e "${RED}✗ $MAX_CONSECUTIVE_FAILURES consecutive failures — shutting down.${NC}"
                break 2
            fi
        fi

        sleep 2
    done

    # --- Advance phase (bash computes next frontier) ---

    # Accumulate current frontier entries before overwriting FRONTIER.md
    ALL_VISITED+=$(awk '/^## Explore/{found=1; next} /^## /{found=0} found && /[^ \t]/{print $1}' "$FRONTIER")$'\n'

    LAYER=$((LAYER + 1))
    MAX_DEPTH=$(awk '/^## Max Depth/{found=1; next} found && /[0-9]/{gsub(/[^0-9]/,""); print; exit}' "$CONTEXT")

    if [ "$LAYER" -ge "$MAX_DEPTH" ]; then
        echo -e "${YELLOW}Reached max depth: $MAX_DEPTH${NC}"
        break
    fi

    if ! compute_next_frontier "$LAYER"; then
        echo -e "${GREEN}No new frontier files — all targets explored${NC}"
        break
    fi

    echo ""
    echo -e "${CYAN}── Layer $LAYER frontier ──${NC}"
    awk '/^## Explore/{found=1; next} /^## /{found=0} found && /[^ \t]/{print "  " $0}' "$FRONTIER"
    echo ""
done

# --- Final banner ---

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}           SCOUT LOOP FINISHED ($ITERATION iterations)          ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Layers:         $LAYER"
echo -e "  Proven edges:   $(count_proven)"
echo -e "  Irrelevant:     $(count_irrelevant)"
echo -e "  Output:         scout/QUEUE.md"
echo ""
