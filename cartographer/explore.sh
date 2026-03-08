#!/bin/bash
#
# Cartographer — Autonomous codebase exploration loop
#
# A single-agent approach that maps codebases file-by-file.
# The map lives on disk (split into many small files), not in context.
# Each iteration picks unexplored nodes from the queue, explores them,
# and writes results back. Over many iterations a complete dependency
# graph emerges.
#
# Usage:
#   ./cartographer/explore.sh                  # Claude, use scope.json budget
#   ./cartographer/explore.sh 10               # Claude, max 10 iterations
#   ./cartographer/explore.sh codex 10         # Codex, max 10 iterations
#   ./cartographer/explore.sh gemini 10        # Gemini, max 10 iterations
#   ./cartographer/explore.sh copilot 10       # Copilot, max 10 iterations
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Paths (relative to cartographer/) ---

EXPLORATION_DIR="$SCRIPT_DIR/exploration"
SCOPE_FILE="$EXPLORATION_DIR/scope.json"
QUEUE_FILE="$EXPLORATION_DIR/queue.json"
INDEX_FILE="$EXPLORATION_DIR/index.json"
STATS_FILE="$EXPLORATION_DIR/stats.json"
FINDINGS_FILE="$EXPLORATION_DIR/findings.md"
NODES_DIR="$EXPLORATION_DIR/nodes"
EDGES_DIR="$EXPLORATION_DIR/edges"
PROMPT_FILE="$SCRIPT_DIR/PROMPT.md"
LOG_DIR="$SCRIPT_DIR/logs"

# ============================================================
# Testable functions
# ============================================================

# Returns the number of pending nodes in queue.json
# Usage: queue_pending_count <queue_file>
queue_pending_count() {
    local qfile="${1:-$QUEUE_FILE}"
    if [ ! -f "$qfile" ]; then
        echo "0"
        return
    fi
    # Count objects in the "pending" array by counting "node" keys
    local count
    count=$(grep -c '"node"' "$qfile" 2>/dev/null || true)
    # But we need to only count inside the pending array, not explored.
    # Since "explored" is a flat string array (no "node" keys), grep for
    # "node" only matches pending items. This is safe for our JSON shape.
    echo "${count:-0}"
}

# Returns 0 (true) if budget is exhausted, 1 (false) otherwise
# Usage: is_budget_exhausted <stats_file> <scope_file>
is_budget_exhausted() {
    local sfile="${1:-$STATS_FILE}"
    local scfile="${2:-$SCOPE_FILE}"

    if [ ! -f "$sfile" ] || [ ! -f "$scfile" ]; then
        return 1
    fi

    local nodes_explored max_nodes iteration max_iterations
    nodes_explored=$(grep -o '"total_nodes_explored":[[:space:]]*[0-9]*' "$sfile" | grep -o '[0-9]*$')
    max_nodes=$(grep -o '"max_nodes":[[:space:]]*[0-9]*' "$scfile" | grep -o '[0-9]*$')
    iteration=$(grep -o '"last_iteration":[[:space:]]*[0-9]*' "$sfile" | grep -o '[0-9]*$')
    max_iterations=$(grep -o '"max_iterations":[[:space:]]*[0-9]*' "$scfile" | grep -o '[0-9]*$')

    nodes_explored="${nodes_explored:-0}"
    max_nodes="${max_nodes:-999}"
    iteration="${iteration:-0}"
    max_iterations="${max_iterations:-999}"

    if [ "$nodes_explored" -ge "$max_nodes" ] || [ "$iteration" -ge "$max_iterations" ]; then
        return 0
    fi
    return 1
}

# Sanitize a file path into a safe filename
# e.g. "src/foo/bar.ts" → "src__foo__bar.ts"
# Usage: sanitize_node_name <path>
sanitize_node_name() {
    local path="$1"
    echo "$path" | sed 's|/|__|g'
}

# Detect completion signals in agent output
# Returns 0 and prints the signal name if found, 1 if no signal
# Usage: detect_completion <output_text_or_file>
detect_completion() {
    local input="$1"
    local content

    if [ -f "$input" ]; then
        content=$(cat "$input")
    else
        content="$input"
    fi

    if echo "$content" | grep -q 'MAP_COMPLETE'; then
        echo "MAP_COMPLETE"
        return 0
    fi
    if echo "$content" | grep -q 'BUDGET_REACHED'; then
        echo "BUDGET_REACHED"
        return 0
    fi
    if echo "$content" | grep -q 'CONTEXT_FULL'; then
        echo "CONTEXT_FULL"
        return 0
    fi
    return 1
}

# Initialize exploration directory with seed data
# Usage: init_exploration <seed_file> [exploration_dir]
init_exploration() {
    local seed="$1"
    local edir="${2:-$EXPLORATION_DIR}"

    mkdir -p "$edir/nodes" "$edir/edges"

    # queue.json — seed as only pending node
    cat > "$edir/queue.json" << QEOF
{
  "pending": [
    {
      "node": "$seed",
      "discovered_from": "seed",
      "reason": "starting point",
      "priority": "high",
      "depth": 0
    }
  ],
  "explored": [],
  "boundaries_recorded": 0,
  "externals_skipped": 0
}
QEOF

    # index.json — empty
    echo '{}' > "$edir/index.json"

    # stats.json — zeroed
    cat > "$edir/stats.json" << SEOF
{
  "seed": "$seed",
  "started": "$(date -I 2>/dev/null || date '+%Y-%m-%d')",
  "total_nodes_discovered": 1,
  "total_nodes_explored": 0,
  "total_edges": 0,
  "last_iteration": 0,
  "coverage_pct": 0
}
SEOF

    # findings.md — header
    cat > "$edir/findings.md" << FEOF
# Exploration Findings

Seed: \`$seed\`
Started: $(date)

FEOF
}

# ============================================================
# Early return for test mode
# ============================================================

if [ "${1:-}" = "--test" ]; then
    return 0 2>/dev/null || exit 0
fi

# ============================================================
# Provider setup
# ============================================================

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

# Pull budget from scope.json if no CLI override
if [ "$MAX_ITERATIONS" -eq 0 ] && [ -f "$SCOPE_FILE" ]; then
    CONFIGURED_MAX=$(grep -o '"max_iterations":[[:space:]]*[0-9]*' "$SCOPE_FILE" | grep -o '[0-9]*$')
    if [ -n "$CONFIGURED_MAX" ]; then
        MAX_ITERATIONS="$CONFIGURED_MAX"
    fi
fi

[ "$MAX_ITERATIONS" -eq 0 ] && MAX_ITERATIONS=20

# ============================================================
# Colors
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# Agent runner
# ============================================================

run_agent() {
    local prompt_file="$1"
    local log_file="$2"
    local iteration="$3"

    local prompt_content
    prompt_content=$(cat "$prompt_file")

    local full_prompt="$prompt_content

Iteration $iteration. Read up to 6 files. Save after EACH node.
"

    if [ "$PIPE_MODE" = "stdin" ]; then
        echo "$full_prompt" | $CLI_CMD $CLI_FLAGS 2>&1 | tee "$log_file"
    elif [ "$PIPE_MODE" = "arg" ]; then
        $CLI_CMD $CLI_FLAGS -p "$full_prompt" 2>&1 | tee "$log_file"
    fi
}

# ============================================================
# Initialize if needed
# ============================================================

if [ ! -f "$INDEX_FILE" ]; then
    SEED=$(grep -o '"seed":[[:space:]]*"[^"]*"' "$SCOPE_FILE" | grep -o '"[^"]*"$' | tr -d '"')
    if [ -z "$SEED" ]; then
        echo "Error: No seed found in scope.json and exploration not initialized"
        exit 1
    fi
    echo -e "${CYAN}Initializing exploration from seed: $SEED${NC}"
    init_exploration "$SEED"
fi

# ============================================================
# Logging
# ============================================================

mkdir -p "$LOG_DIR"
SESSION_LOG="$LOG_DIR/cartographer_session_$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "$SESSION_LOG") 2>&1

# ============================================================
# Validate files
# ============================================================

for f in "$SCOPE_FILE" "$QUEUE_FILE" "$INDEX_FILE" "$STATS_FILE" "$PROMPT_FILE"; do
    if [ ! -f "$f" ]; then
        echo -e "${RED}Error: $(basename "$f") not found at $f${NC}"
        exit 1
    fi
done

# ============================================================
# Banner
# ============================================================

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}                  CARTOGRAPHER LOOP STARTING                   ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}Provider:${NC}       $PROVIDER ($CLI_CMD)"
echo -e "${BLUE}Max iterations:${NC} $MAX_ITERATIONS"
echo -e "${BLUE}Scope:${NC}          $(basename "$SCOPE_FILE")"
echo -e "${BLUE}Log:${NC}            $SESSION_LOG"
echo ""
echo -e "${CYAN}Single-agent loop: read queue → explore nodes → save → repeat${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

# ============================================================
# Main loop
# ============================================================

CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=3

for i in $(seq 1 "$MAX_ITERATIONS"); do

    # --- Pre-check: queue empty? ---
    PENDING=$(queue_pending_count "$QUEUE_FILE")
    if [ "$PENDING" -eq 0 ]; then
        echo -e "${GREEN}Queue empty. Exploration complete.${NC}"
        break
    fi

    # --- Pre-check: budget exhausted? ---
    if is_budget_exhausted "$STATS_FILE" "$SCOPE_FILE"; then
        echo -e "${YELLOW}Budget exhausted. Stopping.${NC}"
        break
    fi

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo -e "${PURPLE}════════════════════ ITERATION $i / $MAX_ITERATIONS ════════════════════${NC}"
    echo -e "${BLUE}[$TIMESTAMP]${NC}"
    echo -e "  Pending nodes: $PENDING"
    echo ""

    LOG_FILE="$LOG_DIR/cartographer_iter_${i}_$(date '+%Y%m%d_%H%M%S').log"

    # --- Run agent ---
    AGENT_OUTPUT=""
    if AGENT_OUTPUT=$(cd "$PROJECT_ROOT" && run_agent "$PROMPT_FILE" "$LOG_FILE" "$i"); then

        # Check for completion signals
        SIGNAL=""
        if SIGNAL=$(detect_completion "$LOG_FILE"); then
            case "$SIGNAL" in
                MAP_COMPLETE)
                    echo -e "${GREEN}Map complete! All in-scope nodes explored.${NC}"
                    break
                    ;;
                BUDGET_REACHED)
                    echo -e "${YELLOW}Budget limit reached. Check findings.md for coverage.${NC}"
                    break
                    ;;
                CONTEXT_FULL)
                    echo -e "${CYAN}Context full — agent checkpointed. Continuing next iteration.${NC}"
                    CONSECUTIVE_FAILURES=0
                    ;;
            esac
        else
            echo -e "${GREEN}Iteration $i completed${NC}"
            CONSECUTIVE_FAILURES=0
        fi

    else
        echo -e "${RED}Agent failed on iteration $i${NC}"
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        tail -5 "$LOG_FILE" 2>/dev/null || true
        if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
            echo -e "${RED}$MAX_CONSECUTIVE_FAILURES consecutive failures — stopping.${NC}"
            break
        fi
    fi

    sleep 3
done

# ============================================================
# Final banner
# ============================================================

TOTAL_EXPLORED=$(grep -o '"total_nodes_explored":[[:space:]]*[0-9]*' "$STATS_FILE" 2>/dev/null | grep -o '[0-9]*$' || echo "?")
TOTAL_DISCOVERED=$(grep -o '"total_nodes_discovered":[[:space:]]*[0-9]*' "$STATS_FILE" 2>/dev/null | grep -o '[0-9]*$' || echo "?")

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}              CARTOGRAPHER LOOP FINISHED                       ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Nodes explored:    $TOTAL_EXPLORED"
echo -e "  Nodes discovered:  $TOTAL_DISCOVERED"
echo -e "  Output:            cartographer/exploration/"
echo ""
