#!/bin/bash
#
# Cartographer — Script-driven codebase exploration loop
#
# The pre-phase produces a complete scope.json. This script iterates
# through all in-scope files, feeding batches to an AI agent that
# describes each file. The script controls iteration — what files
# to explore, when to stop. The agent is a pure file analyzer.
#
# Usage:
#   ./cartographer/explore.sh --init             # Initialize from complete scope.json
#   ./cartographer/explore.sh                    # Claude, auto iteration limit
#   ./cartographer/explore.sh 10                 # Claude, max 10 iterations
#   ./cartographer/explore.sh codex 10           # Codex, max 10 iterations
#   ./cartographer/explore.sh gemini 10          # Gemini, max 10 iterations
#   ./cartographer/explore.sh copilot 10         # Copilot, max 10 iterations
#   ./cartographer/explore.sh cursor 10          # Cursor, max 10 iterations
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# --- Paths ---

EXPLORATION_DIR="${EXPLORATION_DIR:-$SCRIPT_DIR/exploration}"
SCOPE_FILE="$EXPLORATION_DIR/scope.json"
QUEUE_ALL="$EXPLORATION_DIR/queue_all.txt"
QUEUE_EXPLORED="$EXPLORATION_DIR/queue_explored.txt"
INDEX_FILE="$EXPLORATION_DIR/index.json"
FINDINGS_FILE="$EXPLORATION_DIR/findings.md"
NODES_DIR="$EXPLORATION_DIR/nodes"
EDGES_DIR="$EXPLORATION_DIR/edges"
PROMPT_FILE="$SCRIPT_DIR/PROMPT.md"
LOG_DIR="$SCRIPT_DIR/logs"

BATCH_SIZE=3

# ============================================================
# Testable functions
# ============================================================

# Returns the number of pending files (in queue_all but not queue_explored)
# Usage: queue_pending_count <queue_all_file> <queue_explored_file>
queue_pending_count() {
    local all_file="${1:-$QUEUE_ALL}"
    local explored_file="${2:-$QUEUE_EXPLORED}"

    if [ ! -f "$all_file" ]; then
        echo "0"
        return
    fi

    # If explored file doesn't exist or is empty, all are pending
    if [ ! -f "$explored_file" ] || [ ! -s "$explored_file" ]; then
        wc -l < "$all_file" | tr -d ' '
        return
    fi

    comm -23 <(sort "$all_file") <(sort "$explored_file") | wc -l | tr -d ' '
}

# Sanitize a file path into a safe filename
# e.g. "src/foo/bar.ts" → "src__foo__bar.ts"
# Usage: sanitize_node_name <path>
sanitize_node_name() {
    local path="$1"
    echo "$path" | sed 's|/|__|g'
}

# discover_scope_files <scope_file> <project_root>
# Finds all files under explore_within directories.
# Prints one file path per line (relative to project root).
discover_scope_files() {
    local scope_file="$1"
    local root="$2"

    # Read explore_within globs — strip trailing /** or /*
    local ew_entries
    ew_entries=$(grep '"explore_within"' "$scope_file" | grep -o '"[^"]*"' | grep -v 'explore_within' | tr -d '"')

    # Find files under each explore_within directory
    while IFS= read -r ew_glob; do
        [ -z "$ew_glob" ] && continue
        local scope_dir="${ew_glob%%/\*\*}"
        scope_dir="${scope_dir%%/\*}"
        local full_dir="$root/$scope_dir"
        [ -d "$full_dir" ] || continue

        find "$full_dir" -type f | sed "s|^$root/||"
    done <<< "$ew_entries" | sort
}

# ============================================================
# Early return for test mode
# ============================================================

if [ "${1:-}" = "--test" ]; then
    return 0 2>/dev/null || exit 0
fi

# ============================================================
# --dry-run mode: show matching files without creating state
# ============================================================

if [ "${1:-}" = "--dry-run" ]; then
    if [ ! -f "$SCOPE_FILE" ]; then
        echo "Error: scope.json not found at $SCOPE_FILE"
        exit 1
    fi

    discover_scope_files "$SCOPE_FILE" "$PROJECT_ROOT"
    echo "---"
    echo "$(discover_scope_files "$SCOPE_FILE" "$PROJECT_ROOT" | wc -l | tr -d ' ') files match"
    exit 0
fi

# ============================================================
# --init mode: validate complete scope.json and initialize state
# ============================================================

if [ "${1:-}" = "--init" ]; then
    if [ ! -f "$SCOPE_FILE" ]; then
        echo "Error: scope.json not found at $SCOPE_FILE"
        echo "Run the pre-phase first to produce a complete scope.json."
        exit 1
    fi

    # Validate scope.json has all required fields
    missing=""
    grep -q '"seed"' "$SCOPE_FILE" || missing="$missing seed"
    grep -q '"explore_within"' "$SCOPE_FILE" || missing="$missing explore_within"
    grep -q '"boundary_packages"' "$SCOPE_FILE" || missing="$missing boundary_packages"

    if [ -n "$missing" ]; then
        echo "Error: scope.json is incomplete. Missing:$missing"
        echo "Run the pre-phase to produce a complete scope.json."
        exit 1
    fi

    # Clean old state
    rm -rf "$NODES_DIR" "$EDGES_DIR"
    rm -f "$QUEUE_ALL" "$QUEUE_EXPLORED" "$INDEX_FILE" "$FINDINGS_FILE"

    # Discover all in-scope files
    discover_scope_files "$SCOPE_FILE" "$PROJECT_ROOT" > "$QUEUE_ALL"

    local_count=$(wc -l < "$QUEUE_ALL" | tr -d ' ')
    if [ "$local_count" -eq 0 ]; then
        echo "Error: no files found matching explore_within globs"
        rm -f "$QUEUE_ALL"
        exit 1
    fi

    # Create empty explored file
    touch "$QUEUE_EXPLORED"

    # Create empty index.json
    echo '{}' > "$INDEX_FILE"

    # Create findings.md header
    cat > "$FINDINGS_FILE" << FEOF
# Exploration Findings

Started: $(date)

FEOF

    # Create output dirs
    mkdir -p "$NODES_DIR" "$EDGES_DIR"

    # Print summary banner
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  CARTOGRAPHER --init complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Queued:      $local_count files"
    echo ""
    echo "  Run ./cartographer/explore.sh to start exploring."
    echo ""
    exit 0
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
    cursor)
        CLI_CMD="${CURSOR_CMD:-agent}"
        CLI_FLAGS="-p --yolo"
        [ -n "${CURSOR_MODEL:-}" ] && CLI_FLAGS="$CLI_FLAGS -m $CURSOR_MODEL"
        PIPE_MODE="stdin"
        ;;
    *)
        echo "Unknown provider: $PROVIDER"
        echo "Supported: claude, codex, gemini, copilot, cursor"
        exit 1
        ;;
esac

if ! command -v "$CLI_CMD" &> /dev/null; then
    echo "Error: $CLI_CMD not found"
    exit 1
fi

# Compute safety max_iterations from queue size if no CLI override
if [ "$MAX_ITERATIONS" -eq 0 ] && [ -f "$QUEUE_ALL" ]; then
    QUEUED=$(wc -l < "$QUEUE_ALL" | tr -d ' ')
    # 2x expected batches — generous safety margin for retries
    MAX_ITERATIONS=$(( (QUEUED + BATCH_SIZE - 1) / BATCH_SIZE * 2 ))
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
    local batch_files="$3"

    local prompt_content
    prompt_content=$(cat "$prompt_file")

    local full_prompt="$prompt_content

Explore these files:
$batch_files
"

    if [ "$PIPE_MODE" = "stdin" ]; then
        echo "$full_prompt" | $CLI_CMD $CLI_FLAGS 2>&1 | tee "$log_file"
    elif [ "$PIPE_MODE" = "arg" ]; then
        $CLI_CMD $CLI_FLAGS -p "$full_prompt" 2>&1 | tee "$log_file"
    fi
}

# ============================================================
# Validate state
# ============================================================

for f in "$SCOPE_FILE" "$QUEUE_ALL" "$INDEX_FILE" "$PROMPT_FILE"; do
    if [ ! -f "$f" ]; then
        echo -e "${RED}Error: $(basename "$f") not found at $f${NC}"
        echo "Run ./cartographer/explore.sh --init first."
        exit 1
    fi
done

# Ensure queue_explored exists
[ -f "$QUEUE_EXPLORED" ] || touch "$QUEUE_EXPLORED"

# ============================================================
# Logging
# ============================================================

mkdir -p "$LOG_DIR"
SESSION_LOG="$LOG_DIR/cartographer_session_$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "$SESSION_LOG") 2>&1

# ============================================================
# Banner
# ============================================================

DISCOVERED=$(wc -l < "$QUEUE_ALL" | tr -d ' ')
EXPLORED=$(wc -l < "$QUEUE_EXPLORED" | tr -d ' ')
PENDING=$((DISCOVERED - EXPLORED))

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}                  CARTOGRAPHER LOOP STARTING                   ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}Provider:${NC}       $PROVIDER ($CLI_CMD)"
echo -e "${BLUE}Max iterations:${NC} $MAX_ITERATIONS"
echo -e "${BLUE}Scope:${NC}          $DISCOVERED files, $PENDING pending"
echo -e "${BLUE}Log:${NC}            $SESSION_LOG"
echo ""
echo -e "${CYAN}Script-driven loop: compute pending → batch to agent → check output → repeat${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

# ============================================================
# Main loop
# ============================================================

CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=3

for i in $(seq 1 "$MAX_ITERATIONS"); do

    # --- Compute pending batch ---
    PENDING_FILES=$(comm -23 <(sort "$QUEUE_ALL") <(sort "$QUEUE_EXPLORED"))
    BATCH=$(echo "$PENDING_FILES" | head -n "$BATCH_SIZE")

    if [ -z "$BATCH" ]; then
        echo -e "${GREEN}All files explored. Done.${NC}"
        break
    fi


    BATCH_COUNT=$(echo "$BATCH" | wc -l | tr -d ' ')
    PENDING_COUNT=$(echo "$PENDING_FILES" | wc -l | tr -d ' ')
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo -e "${PURPLE}════════════════════ ITERATION $i / $MAX_ITERATIONS ════════════════════${NC}"
    echo -e "${BLUE}[$TIMESTAMP]${NC}"
    echo -e "  Pending: $PENDING_COUNT files, batch: $BATCH_COUNT"
    echo ""

    LOG_FILE="$LOG_DIR/cartographer_iter_${i}_$(date '+%Y%m%d_%H%M%S').log"

    # --- Run agent ---
    if cd "$PROJECT_ROOT" && run_agent "$PROMPT_FILE" "$LOG_FILE" "$BATCH"; then

        # Check which files got node output
        NEWLY_EXPLORED=0
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            local_sanitized=$(sanitize_node_name "$file")
            if [ -f "$NODES_DIR/${local_sanitized}.json" ]; then
                echo "$file" >> "$QUEUE_EXPLORED"
                NEWLY_EXPLORED=$((NEWLY_EXPLORED + 1))
            fi
        done <<< "$BATCH"

        echo -e "${GREEN}Iteration $i: $NEWLY_EXPLORED/$BATCH_COUNT files explored${NC}"
        CONSECUTIVE_FAILURES=0

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

TOTAL_DISCOVERED=$(wc -l < "$QUEUE_ALL" | tr -d ' ')
TOTAL_EXPLORED=$(wc -l < "$QUEUE_EXPLORED" | tr -d ' ')

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}              CARTOGRAPHER LOOP FINISHED                       ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Files explored:   $TOTAL_EXPLORED / $TOTAL_DISCOVERED"
echo -e "  Output:           cartographer/exploration/"
echo ""
