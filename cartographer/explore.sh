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
# Usage: init_exploration <exploration_dir> <seed1> [seed2] [seed3] ...
init_exploration() {
    local edir="$1"
    shift
    local seeds=("$@")
    local first_seed="${seeds[0]}"
    local seed_count=${#seeds[@]}

    mkdir -p "$edir/nodes" "$edir/edges"

    # queue.json — all seeds as pending nodes
    local pending_items=""
    local first_item=true
    for s in "${seeds[@]}"; do
        local item
        item=$(cat << IEOF
    {
      "node": "$s",
      "discovered_from": "seed",
      "reason": "starting point",
      "priority": "high",
      "depth": 0
    }
IEOF
)
        if $first_item; then
            pending_items="$item"
            first_item=false
        else
            pending_items="$pending_items,
$item"
        fi
    done

    cat > "$edir/queue.json" << QEOF
{
  "pending": [
$pending_items
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
  "seed": "$first_seed",
  "started": "$(date -I 2>/dev/null || date '+%Y-%m-%d')",
  "total_nodes_discovered": $seed_count,
  "total_nodes_explored": 0,
  "total_edges": 0,
  "last_iteration": 0,
  "coverage_pct": 0
}
SEOF

    # findings.md — header
    local seed_list=""
    for s in "${seeds[@]}"; do
        seed_list="$seed_list
- \`$s\`"
    done

    cat > "$edir/findings.md" << FEOF
# Exploration Findings

Seeds:$seed_list

Started: $(date)

FEOF
}

# discover_scope_files <scope_file> <project_root>
# Finds all files under explore_within directories, excluding ignore patterns.
# Prints one file path per line (relative to project root).
discover_scope_files() {
    local scope_file="$1"
    local root="$2"

    # Read explore_within globs — strip trailing /** or /*
    local ew_entries
    ew_entries=$(grep '"explore_within"' "$scope_file" | grep -o '"[^"]*"' | grep -v 'explore_within' | tr -d '"')

    # Read ignore globs, convert to grep -v patterns
    # e.g. "**/*.md" → "\.md$", "**/node_modules/**" → "/node_modules/"
    local grep_excludes=""
    local ignore_entries
    ignore_entries=$(grep '"ignore"' "$scope_file" | grep -o '"[^"]*"' | grep -v 'ignore' | tr -d '"')
    while IFS= read -r ig; do
        [ -z "$ig" ] && continue
        local pat=""
        case "$ig" in
            **/node_modules/**)  pat="/node_modules/" ;;
            **/vendor/**)        pat="/vendor/" ;;
            **/__pycache__/**)   pat="/__pycache__/" ;;
            *\*.*)
                # **/*.md → \.md$
                local ext
                ext=$(echo "$ig" | sed 's/.*\*//')  # e.g. ".md", ".d.ts", ".css"
                ext=$(echo "$ext" | sed 's/\./\\./g')  # escape dots
                pat="${ext}$"
                ;;
        esac
        [ -z "$pat" ] && continue
        if [ -z "$grep_excludes" ]; then
            grep_excludes="$pat"
        else
            grep_excludes="$grep_excludes|$pat"
        fi
    done <<< "$ignore_entries"

    # Find files under each explore_within directory
    while IFS= read -r ew_glob; do
        [ -z "$ew_glob" ] && continue
        local scope_dir="${ew_glob%%/\*\*}"
        scope_dir="${scope_dir%%/\*}"
        local full_dir="$root/$scope_dir"
        [ -d "$full_dir" ] || continue

        if [ -n "$grep_excludes" ]; then
            find "$full_dir" -type f | sed "s|^$root/||" | grep -vE "$grep_excludes"
        else
            find "$full_dir" -type f | sed "s|^$root/||"
        fi
    done <<< "$ew_entries" | sort
}

# discover_boundaries <explore_within_glob> [project_root]
# Prints sibling directories of the scope parent, one per line.
# "dependency-cruiser/src/report/**" → parent "dependency-cruiser/src" → siblings
discover_boundaries() {
    local glob="$1"
    local root="${2:-.}"

    # Strip trailing /** or /*
    local scope_dir="${glob%%/\*\*}"
    scope_dir="${scope_dir%%/\*}"

    local parent_dir
    parent_dir=$(dirname "$scope_dir")

    local full_parent="$root/$parent_dir"
    if [ ! -d "$full_parent" ]; then
        return 0
    fi

    local scope_basename name
    scope_basename=$(basename "$scope_dir")

    for d in "$full_parent"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        if [ "$name" != "$scope_basename" ]; then
            echo "$parent_dir/$name"
        fi
    done
}

# detect_ignore_patterns <seed_file>
# Prints comma-separated ignore globs based on first seed's file extension.
detect_ignore_patterns() {
    local seed="$1"
    local ext="${seed##*.}"

    case "$ext" in
        mjs|cjs|js|jsx)
            echo "**/*.md,**/*.d.ts,**/*.ts,**/*.css,**/node_modules/**"
            ;;
        ts|tsx)
            echo "**/*.md,**/*.css,**/node_modules/**"
            ;;
        go)
            echo "**/*_test.go,**/vendor/**,**/*.md"
            ;;
        py)
            echo "**/__pycache__/**,**/*.pyc,**/*.md"
            ;;
        *)
            echo "**/node_modules/**,**/vendor/**,**/*.md"
            ;;
    esac
}

# complete_scope <scope_file> [project_root]
# Reads a minimal scope.json (seed + explore_within), fills missing fields, writes back.
complete_scope() {
    local scope_file="$1"
    local root="${2:-.}"

    if [ ! -f "$scope_file" ]; then
        echo "Error: scope file not found: $scope_file" >&2
        return 1
    fi

    # Read seed — support both string and array formats
    local seed_line first_seed seeds_json
    seed_line=$(grep '"seed"' "$scope_file")
    if echo "$seed_line" | grep -q '\['; then
        # Array format: extract [...] from the seed line
        seeds_json=$(echo "$seed_line" | sed 's/.*"seed"[[:space:]]*:[[:space:]]*//' | sed 's/[[:space:]]*,*[[:space:]]*$//')
        first_seed=$(echo "$seeds_json" | grep -o '"[^"]*"' | head -1 | tr -d '"')
    else
        # String format
        first_seed=$(echo "$seed_line" | grep -o '"[^"]*"' | tail -1 | tr -d '"')
        seeds_json="\"$first_seed\""
    fi

    # Read explore_within array
    local ew_entries
    ew_entries=$(grep '"explore_within"' "$scope_file" | grep -o '"[^"]*"' | grep -v 'explore_within' | tr -d '"')

    # Discover boundary packages from all explore_within globs
    local boundaries=""
    local ew_glob
    while IFS= read -r ew_glob; do
        [ -z "$ew_glob" ] && continue
        local sibs
        sibs=$(discover_boundaries "$ew_glob" "$root")
        if [ -n "$sibs" ]; then
            if [ -n "$boundaries" ]; then
                boundaries="$boundaries"$'\n'"$sibs"
            else
                boundaries="$sibs"
            fi
        fi
    done <<< "$ew_entries"

    # Deduplicate boundaries
    if [ -n "$boundaries" ]; then
        boundaries=$(echo "$boundaries" | sort -u)
    fi

    # Detect ignore patterns
    local ignore_csv
    ignore_csv=$(detect_ignore_patterns "$first_seed")

    # Read existing budget values or use defaults
    local max_iter max_nodes max_depth
    max_iter=$(grep -o '"max_iterations":[[:space:]]*[0-9]*' "$scope_file" 2>/dev/null | grep -o '[0-9]*$' || true)
    max_nodes=$(grep -o '"max_nodes":[[:space:]]*[0-9]*' "$scope_file" 2>/dev/null | grep -o '[0-9]*$' || true)
    max_depth=$(grep -o '"max_depth_from_seed":[[:space:]]*[0-9]*' "$scope_file" 2>/dev/null | grep -o '[0-9]*$' || true)
    max_iter="${max_iter:-20}"
    max_nodes="${max_nodes:-50}"
    max_depth="${max_depth:-5}"

    # Reconstruct explore_within JSON array
    local ew_json=""
    local first_ew=true
    while IFS= read -r ew_glob; do
        [ -z "$ew_glob" ] && continue
        if $first_ew; then
            ew_json="\"$ew_glob\""
            first_ew=false
        else
            ew_json="$ew_json, \"$ew_glob\""
        fi
    done <<< "$ew_entries"

    # Build boundary_packages JSON array
    local bp_json=""
    if [ -n "$boundaries" ]; then
        local first_bp=true
        while IFS= read -r bp; do
            [ -z "$bp" ] && continue
            if $first_bp; then
                bp_json="\"$bp\""
                first_bp=false
            else
                bp_json="$bp_json, \"$bp\""
            fi
        done <<< "$boundaries"
    fi

    # Build ignore JSON array from CSV (disable globbing to protect **)
    local ignore_json=""
    local first_ig=true
    local IFS_OLD="$IFS"
    IFS=','
    set -f
    for ig in $ignore_csv; do
        if $first_ig; then
            ignore_json="\"$ig\""
            first_ig=false
        else
            ignore_json="$ignore_json, \"$ig\""
        fi
    done
    set +f
    IFS="$IFS_OLD"

    # Write completed scope.json
    cat > "$scope_file" << SCEOF
{
  "seed": $seeds_json,
  "boundaries": {
    "explore_within": [$ew_json],
    "boundary_packages": [$bp_json],
    "ignore": [$ignore_json]
  },
  "budget": {
    "max_iterations": $max_iter,
    "max_nodes": $max_nodes,
    "max_depth_from_seed": $max_depth
  }
}
SCEOF
}

# ============================================================
# Early return for test mode
# ============================================================

if [ "${1:-}" = "--test" ]; then
    return 0 2>/dev/null || exit 0
fi

# ============================================================
# --init mode: auto-discover boundaries and initialize state
# ============================================================

if [ "${1:-}" = "--init" ]; then
    if [ ! -f "$SCOPE_FILE" ]; then
        echo "Error: scope.json not found at $SCOPE_FILE"
        echo "Create a minimal scope.json with 'seed' and 'boundaries.explore_within'."
        exit 1
    fi

    # Validate minimal required fields
    if ! grep -q '"seed"' "$SCOPE_FILE"; then
        echo "Error: scope.json missing 'seed' field"
        exit 1
    fi
    if ! grep -q '"explore_within"' "$SCOPE_FILE"; then
        echo "Error: scope.json missing 'boundaries.explore_within' field"
        exit 1
    fi

    # Clean existing exploration state
    rm -rf "$NODES_DIR" "$EDGES_DIR"
    rm -f "$QUEUE_FILE" "$INDEX_FILE" "$STATS_FILE" "$FINDINGS_FILE"

    # Fill in scope.json
    complete_scope "$SCOPE_FILE" "$PROJECT_ROOT"

    # Discover all in-scope files from the filesystem
    all_scope_files=()
    while IFS= read -r f; do
        [ -n "$f" ] && all_scope_files+=("$f")
    done < <(discover_scope_files "$SCOPE_FILE" "$PROJECT_ROOT")

    if [ ${#all_scope_files[@]} -eq 0 ]; then
        echo "Error: no files found matching explore_within globs"
        exit 1
    fi

    # Initialize exploration state with all in-scope files
    init_exploration "$EXPLORATION_DIR" "${all_scope_files[@]}"

    # Print summary — count boundary packages on the single line
    bp_count=$(grep '"boundary_packages"' "$SCOPE_FILE" | grep -o '"[^"]*"' | grep -v '"boundary_packages"' | wc -l)
    bp_count=$(echo "$bp_count" | tr -d ' ')

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  CARTOGRAPHER --init complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Queued:      ${#all_scope_files[@]} files"
    echo "  Boundaries:  $bp_count packages discovered"
    echo "  Budget:      $(grep -o '"max_iterations":[[:space:]]*[0-9]*' "$SCOPE_FILE" | grep -o '[0-9]*$') iterations, $(grep -o '"max_nodes":[[:space:]]*[0-9]*' "$SCOPE_FILE" | grep -o '[0-9]*$') nodes"
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
    init_exploration "$EXPLORATION_DIR" "$SEED"
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
