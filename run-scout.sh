#!/bin/bash
#
# Scout Loop — Queue-driven discovery/proving loop
#
# Mode detection happens HERE in bash, not in the agent prompt.
# The agent gets a single-purpose prompt each iteration.
#
# Logic:
#   1. Count unchecked edges (- [ ]) in scout/QUEUE.md
#   2. If unchecked > 0 → pipe proving prompt (confirm one edge)
#   3. If unchecked = 0 → pipe discovery prompt (find new edges)
#   4. If discovery outputs ALL_DONE → no frontier left, exit
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
DISCOVER_PROMPT="$SCRIPT_DIR/scout/PROMPT_discover.md"
PROVE_PROMPT="$SCRIPT_DIR/scout/PROMPT_prove.md"
LOG_DIR="$SCRIPT_DIR/logs"

mkdir -p "$LOG_DIR"

# --- Validate files ---

for f in "$QUEUE" "$DISCOVER_PROMPT" "$PROVE_PROMPT" \
         "$SCRIPT_DIR/scout/CONTEXT.md" "$SCRIPT_DIR/scout/OVERVIEW.md" \
         "$SCRIPT_DIR/.specify/memory/constitution.md"; do
    if [ ! -f "$f" ]; then
        echo -e "${RED}Error: $(basename "$f") not found at $f${NC}"
        exit 1
    fi
done

# --- Functions ---

count_unchecked() {
    grep -c '^\- \[ \]' "$QUEUE" 2>/dev/null || echo 0
}

count_proven() {
    grep -c '^\- \[x\]' "$QUEUE" 2>/dev/null || echo 0
}

count_irrelevant() {
    # Count lines in irrelevant section (lines starting with "- " after "## Irrelevant")
    awk '/^## Irrelevant/{found=1; next} /^## /{found=0} found && /^- /{count++} END{print count+0}' "$QUEUE"
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
echo -e "${CYAN}Mode is selected automatically each iteration by checking QUEUE.md${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

# --- Main loop ---

ITERATION=0
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=3

while true; do
    # Check max iterations
    if [ $MAX_ITERATIONS -gt 0 ] && [ $ITERATION -ge $MAX_ITERATIONS ]; then
        echo -e "${YELLOW}Reached max iterations: $MAX_ITERATIONS${NC}"
        break
    fi

    ITERATION=$((ITERATION + 1))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # --- Mode detection (the key part — this is bash, not the agent) ---

    UNCHECKED=$(count_unchecked)
    PROVEN=$(count_proven)
    IRRELEVANT=$(count_irrelevant)

    if [ "$UNCHECKED" -gt 0 ]; then
        # Queue cap: if too many unchecked, force proving until it drains
        MODE="prove"
        PROMPT_FILE="$PROVE_PROMPT"
    else
        MODE="discover"
        PROMPT_FILE="$DISCOVER_PROMPT"
    fi

    # --- Iteration banner ---

    echo ""
    echo -e "${PURPLE}════════════════════ ITERATION $ITERATION ════════════════════${NC}"
    echo -e "${BLUE}[$TIMESTAMP]${NC}"
    echo -e "  Mode:       ${CYAN}$MODE${NC}"
    echo -e "  Unchecked:  $UNCHECKED"
    echo -e "  Proven:     $PROVEN"
    echo -e "  Irrelevant: $IRRELEVANT"
    echo ""

    # --- Run agent ---

    LOG_FILE="$LOG_DIR/scout_${MODE}_iter_${ITERATION}_$(date '+%Y%m%d_%H%M%S').log"

    AGENT_OUTPUT=""
    if AGENT_OUTPUT=$(run_agent "$PROMPT_FILE" "$LOG_FILE"); then

        # --- Check completion signals ---

        if echo "$AGENT_OUTPUT" | grep -q "<promise>ALL_DONE</promise>"; then
            echo ""
            echo -e "${GREEN}━━━ ALL_DONE — No frontier remaining. Scout complete. ━━━${NC}"
            echo ""
            echo -e "  Total iterations: $ITERATION"
            echo -e "  Proven edges:     $(count_proven)"
            echo -e "  Irrelevant edges: $(count_irrelevant)"
            echo -e "  Output:           scout/OVERVIEW.md"
            break

        elif echo "$AGENT_OUTPUT" | grep -q "<promise>DONE</promise>"; then
            echo -e "${GREEN}✓ $MODE completed${NC}"
            CONSECUTIVE_FAILURES=0

        else
            echo -e "${YELLOW}⚠ No completion signal — agent may be stuck${NC}"
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))

            if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
                echo -e "${RED}✗ $MAX_CONSECUTIVE_FAILURES consecutive failures — shutting down.${NC}"
                echo -e "${RED}  Check logs: $LOG_DIR${NC}"
                break
            fi

            # Show tail of output for debugging
            echo ""
            echo -e "${CYAN}Last 5 lines:${NC}"
            tail -5 "$LOG_FILE" 2>/dev/null || true
        fi
    else
        echo -e "${RED}✗ Agent execution failed${NC}"
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        tail -5 "$LOG_FILE" 2>/dev/null || true
    fi

    sleep 2
done

# --- Final banner ---

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}           SCOUT LOOP FINISHED ($ITERATION iterations)          ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
