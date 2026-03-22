#!/bin/bash
#
# Cartographer v2 — Wave-based codebase exploration
#
# The pre-phase produces a complete scope.json. This script:
# 1. Queries CGC graph data for the scope
# 2. Runs Sonnet to plan exploration waves (WAVE_PLAN_PROMPT.md)
# 3. Executes waves sequentially, accumulating context (EXPLORE_PROMPT.md)
#
# Usage:
#   ./cartographer/explore.sh --init             # Initialize from scope.json + extract CGC graph
#   ./cartographer/explore.sh                    # Run wave exploration (Sonnet)
#   ./cartographer/explore.sh --incremental      # Re-explore only changed files
#   ./cartographer/explore.sh --dry-run          # Show matching files
#   ./cartographer/explore.sh cursor             # Use cursor provider
#   ./cartographer/explore.sh cursor 10          # Cursor, max 10 wave iterations
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# SOURCE_ROOT is the actual git repo for revision tracking.
# Defaults to PROJECT_ROOT, but can differ when PROJECT_ROOT uses symlinks.
SOURCE_ROOT="${SOURCE_ROOT:-$PROJECT_ROOT}"

# --- Paths ---

EXPLORATION_DIR="${EXPLORATION_DIR:-$SCRIPT_DIR/exploration}"
SCOPE_FILE="$EXPLORATION_DIR/scope.json"
QUEUE_ALL="$EXPLORATION_DIR/queue_all.txt"
QUEUE_EXPLORED="$EXPLORATION_DIR/queue_explored.txt"
INDEX_FILE="$EXPLORATION_DIR/index.json"
FINDINGS_FILE="$EXPLORATION_DIR/findings.md"
NODES_DIR="$EXPLORATION_DIR/nodes"
EDGES_DIR="$EXPLORATION_DIR/edges"
WAVES_FILE="$EXPLORATION_DIR/waves.json"
CGC_GRAPH_FILE="$EXPLORATION_DIR/cgc_graph.json"
REVISION_FILE="$EXPLORATION_DIR/revision.json"
WAVE_PLAN_PROMPT="$SCRIPT_DIR/WAVE_PLAN_PROMPT.md"
EXPLORE_PROMPT="$SCRIPT_DIR/EXPLORE_PROMPT.md"
# v1 prompt kept as fallback reference
V1_PROMPT_FILE="$SCRIPT_DIR/PROMPT.md"
LOG_DIR="$SCRIPT_DIR/logs"

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

# consolidate_nodes — merge all node JSON files into a single array
# Prints JSON array to stdout
consolidate_nodes() {
    python3 -c "
import json, glob, sys
nodes = []
for f in sorted(glob.glob('$NODES_DIR/*.json')):
    with open(f) as fh:
        try:
            nodes.append(json.load(fh))
        except json.JSONDecodeError:
            pass
json.dump(nodes, sys.stdout, indent=2)
"
}

# consolidate_edges — merge all edge JSON files into a single array
consolidate_edges() {
    python3 -c "
import json, glob, sys
edges = []
for f in sorted(glob.glob('$EDGES_DIR/*.json')):
    with open(f) as fh:
        try:
            data = json.load(fh)
            if isinstance(data, list):
                edges.extend(data)
            else:
                edges.append(data)
        except json.JSONDecodeError:
            pass
json.dump(edges, sys.stdout, indent=2)
"
}

# extract_cgc_graph — query CGC for scope dependency data
# Writes cgc_graph.json to exploration dir
extract_cgc_graph() {
    local scope_file="$1"
    local output_file="$2"

    echo "Extracting CGC graph data..."

    python3 -c "
import json, subprocess, sys, os

with open('$scope_file') as f:
    scope = json.load(f)

graph = {
    'files': {},
    'edges': [],
    'stats': {}
}

# Get explore_within directories
ew = scope.get('boundaries', {}).get('explore_within', [])
dirs = []
for g in ew:
    d = g.rstrip('/*').rstrip('/**')
    dirs.append(d)

# Try to get dependency data from cgc
try:
    # Get module-level dependencies
    for d in dirs:
        result = subprocess.run(
            ['cgc', 'analyze', 'deps', d],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            try:
                deps = json.loads(result.stdout)
                if isinstance(deps, dict):
                    graph['deps'] = deps
                elif isinstance(deps, list):
                    graph['edges'].extend(deps)
            except json.JSONDecodeError:
                graph['deps_raw'] = result.stdout.strip()

    # Try callers analysis for fan-in data
    for d in dirs:
        result = subprocess.run(
            ['cgc', 'analyze', 'callers', d],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            try:
                callers = json.loads(result.stdout)
                graph['callers'] = callers
            except json.JSONDecodeError:
                graph['callers_raw'] = result.stdout.strip()

    # Get repo stats
    result = subprocess.run(
        ['cgc', 'stats'],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode == 0 and result.stdout.strip():
        graph['stats_raw'] = result.stdout.strip()

except FileNotFoundError:
    print('Warning: cgc not found, writing minimal graph', file=sys.stderr)
except subprocess.TimeoutExpired:
    print('Warning: cgc timed out, writing partial graph', file=sys.stderr)

with open('$output_file', 'w') as f:
    json.dump(graph, f, indent=2)

print(f'  CGC graph: {len(graph.get(\"edges\", []))} edges', file=sys.stderr)
"
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
# --init mode: validate scope.json, extract CGC graph, init state
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
    rm -f "$WAVES_FILE" "$CGC_GRAPH_FILE" "$REVISION_FILE"

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

    # Extract CGC graph data
    if command -v cgc &>/dev/null; then
        extract_cgc_graph "$SCOPE_FILE" "$CGC_GRAPH_FILE"
    else
        echo '{"note": "cgc not available — wave planning will use file list only"}' > "$CGC_GRAPH_FILE"
        echo "  Warning: cgc not found. Wave planning will work without graph data."
    fi

    # Initialize revision tracking
    local_sha=$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
    cat > "$REVISION_FILE" << REOF
{
  "last_explored": "$local_sha",
  "last_synthesized": null,
  "files_at_generation": $(python3 -c "import json; print(json.dumps([l.strip() for l in open('$QUEUE_ALL') if l.strip()]))"),
  "cross_scope_revision": null
}
REOF

    # Print summary banner
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  CARTOGRAPHER v2 --init complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Queued:      $local_count files"
    echo "  CGC graph:   $CGC_GRAPH_FILE"
    echo "  Revision:    $local_sha"
    echo ""
    echo "  Run ./cartographer/explore.sh to start wave exploration."
    echo ""
    exit 0
fi

# ============================================================
# --incremental mode: re-explore only changed files
# ============================================================

if [ "${1:-}" = "--incremental" ]; then
    if [ ! -f "$REVISION_FILE" ]; then
        echo "Error: revision.json not found. Run full exploration first."
        exit 1
    fi

    LAST_SHA=$(python3 -c "import json; print(json.load(open('$REVISION_FILE'))['last_explored'])")
    CURRENT_SHA=$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")

    if [ "$LAST_SHA" = "$CURRENT_SHA" ]; then
        echo "No changes since last exploration ($LAST_SHA). Nothing to do."
        exit 0
    fi

    echo "Incremental update: $LAST_SHA → $CURRENT_SHA"

    # Find changed files
    CHANGED_FILES=$(git -C "$SOURCE_ROOT" diff --name-only "$LAST_SHA" HEAD 2>/dev/null || true)

    if [ -z "$CHANGED_FILES" ]; then
        echo "No file changes detected."
        exit 0
    fi

    # Filter to in-scope files
    ALL_SCOPE_FILES=$(cat "$QUEUE_ALL")
    CHANGED_IN_SCOPE=""
    while IFS= read -r changed; do
        [ -z "$changed" ] && continue
        if echo "$ALL_SCOPE_FILES" | grep -qxF "$changed"; then
            CHANGED_IN_SCOPE="$CHANGED_IN_SCOPE
$changed"
        fi
    done <<< "$CHANGED_FILES"

    CHANGED_IN_SCOPE=$(echo "$CHANGED_IN_SCOPE" | sed '/^$/d')

    if [ -z "$CHANGED_IN_SCOPE" ]; then
        echo "No in-scope files changed."
        # Update revision even if no in-scope changes
        python3 -c "
import json
with open('$REVISION_FILE') as f:
    rev = json.load(f)
rev['last_explored'] = '$CURRENT_SHA'
with open('$REVISION_FILE', 'w') as f:
    json.dump(rev, f, indent=2)
"
        exit 0
    fi

    CHANGED_COUNT=$(echo "$CHANGED_IN_SCOPE" | wc -l | tr -d ' ')
    echo "  Changed in-scope files: $CHANGED_COUNT"

    # Remove old nodes/edges for changed files so they get re-explored
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        local_sanitized=$(sanitize_node_name "$file")
        rm -f "$NODES_DIR/${local_sanitized}.json"
        rm -f "$EDGES_DIR/${local_sanitized}.edges.json"
        # Remove from explored queue
        if [ -f "$QUEUE_EXPLORED" ]; then
            grep -vxF "$file" "$QUEUE_EXPLORED" > "$QUEUE_EXPLORED.tmp" || true
            mv "$QUEUE_EXPLORED.tmp" "$QUEUE_EXPLORED"
        fi
    done <<< "$CHANGED_IN_SCOPE"

    # Re-extract CGC graph
    if command -v cgc &>/dev/null; then
        cgc index "$PROJECT_ROOT" 2>/dev/null || true
        extract_cgc_graph "$SCOPE_FILE" "$CGC_GRAPH_FILE"
    fi

    # Create a temporary waves.json for just the changed files
    # with all existing nodes as context
    echo "  Creating incremental wave plan for changed files..."

    # Fall through to the main wave exploration loop
    # The changed files are now un-explored, so the wave loop will pick them up
    shift  # Remove --incremental from args
fi

# ============================================================
# Provider setup
# ============================================================

PROVIDER="${PROVIDER:-claude}"
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

# Default model is sonnet for v2 (was haiku in v1)
CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"

case "$PROVIDER" in
    claude)
        CLI_CMD="${CLAUDE_CMD:-claude}"
        CLI_FLAGS="-p --dangerously-skip-permissions"
        CLI_FLAGS="$CLI_FLAGS --model $CLAUDE_MODEL"
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
    local prompt_content="$1"
    local log_file="$2"

    if [ "$PIPE_MODE" = "stdin" ]; then
        echo "$prompt_content" | $CLI_CMD $CLI_FLAGS 2>&1 | tee "$log_file"
    elif [ "$PIPE_MODE" = "arg" ]; then
        $CLI_CMD $CLI_FLAGS -p "$prompt_content" 2>&1 | tee "$log_file"
    fi
}

# ============================================================
# Validate state
# ============================================================

for f in "$SCOPE_FILE" "$QUEUE_ALL" "$EXPLORE_PROMPT"; do
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
# Wave Planning Phase
# ============================================================

DISCOVERED=$(wc -l < "$QUEUE_ALL" | tr -d ' ')
EXPLORED=$(wc -l < "$QUEUE_EXPLORED" | tr -d ' ')
PENDING=$((DISCOVERED - EXPLORED))

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}              CARTOGRAPHER v2 WAVE EXPLORATION                  ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}Provider:${NC}       $PROVIDER ($CLI_CMD)"
echo -e "${BLUE}Model:${NC}          $CLAUDE_MODEL"
echo -e "${BLUE}Scope:${NC}          $DISCOVERED files, $PENDING pending"
echo -e "${BLUE}Log:${NC}            $SESSION_LOG"
echo ""

# Plan waves if waves.json doesn't exist or has no unexplored waves
if [ ! -f "$WAVES_FILE" ] || [ "$PENDING" -eq "$DISCOVERED" ]; then
    echo -e "${CYAN}Phase 1: Wave Planning${NC}"
    echo "  Running Sonnet to plan exploration order..."
    echo ""

    # Build wave planning prompt
    WAVE_PLAN_CONTENT=$(cat "$WAVE_PLAN_PROMPT")

    SCOPE_JSON=$(cat "$SCOPE_FILE")
    CGC_GRAPH=""
    [ -f "$CGC_GRAPH_FILE" ] && CGC_GRAPH=$(cat "$CGC_GRAPH_FILE")
    FILE_LIST=$(cat "$QUEUE_ALL")

    WAVE_PROMPT="$WAVE_PLAN_CONTENT

---

## scope.json

\`\`\`json
$SCOPE_JSON
\`\`\`

## CGC Graph Data

\`\`\`json
$CGC_GRAPH
\`\`\`

## Files to Plan

\`\`\`
$FILE_LIST
\`\`\`
"

    WAVE_LOG="$LOG_DIR/wave_plan_$(date '+%Y%m%d_%H%M%S').log"

    if run_agent "$WAVE_PROMPT" "$WAVE_LOG"; then
        if [ -f "$WAVES_FILE" ]; then
            WAVE_COUNT=$(python3 -c "import json; print(len(json.load(open('$WAVES_FILE'))['waves']))" 2>/dev/null || echo "?")
            echo ""
            echo -e "${GREEN}  Wave plan created: $WAVE_COUNT waves${NC}"
        else
            echo -e "${YELLOW}  Warning: waves.json not created by agent. Creating default single-wave plan.${NC}"
            # Fallback: put all files in one wave
            python3 -c "
import json
files = [l.strip() for l in open('$QUEUE_ALL') if l.strip()]
plan = {'waves': [{'id': 1, 'files': files, 'rationale': 'Default: all files in single wave (wave planning did not produce output)'}]}
with open('$WAVES_FILE', 'w') as f:
    json.dump(plan, f, indent=2)
print(f'  Created fallback plan with {len(files)} files in 1 wave')
"
        fi
    else
        echo -e "${RED}  Wave planning failed. Creating default plan.${NC}"
        python3 -c "
import json
files = [l.strip() for l in open('$QUEUE_ALL') if l.strip()]
plan = {'waves': [{'id': 1, 'files': files, 'rationale': 'Default: all files in single wave (wave planning failed)'}]}
with open('$WAVES_FILE', 'w') as f:
    json.dump(plan, f, indent=2)
"
    fi

    echo ""
fi

# ============================================================
# Wave Execution Loop
# ============================================================

echo -e "${CYAN}Phase 2: Wave Exploration${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

NUM_WAVES=$(python3 -c "import json; print(len(json.load(open('$WAVES_FILE'))['waves']))" 2>/dev/null || echo "0")

if [ "$NUM_WAVES" -eq 0 ]; then
    echo -e "${RED}Error: waves.json has no waves${NC}"
    exit 1
fi

# Compute max iterations: one per wave, with safety margin
if [ "$MAX_ITERATIONS" -eq 0 ]; then
    MAX_ITERATIONS=$((NUM_WAVES * 2))
fi
[ "$MAX_ITERATIONS" -lt "$NUM_WAVES" ] && MAX_ITERATIONS="$NUM_WAVES"

CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=3
WAVE_INDEX=0

for i in $(seq 1 "$MAX_ITERATIONS"); do

    # Find next wave with unexplored files
    WAVE_FILES=""
    WAVE_RATIONALE=""
    while [ "$WAVE_INDEX" -lt "$NUM_WAVES" ]; do
        # Get wave data
        WAVE_DATA=$(python3 -c "
import json
waves = json.load(open('$WAVES_FILE'))['waves']
w = waves[$WAVE_INDEX]
print(json.dumps(w))
")
        WAVE_FILES=$(echo "$WAVE_DATA" | python3 -c "import json,sys; [print(f) for f in json.load(sys.stdin)['files']]")
        WAVE_RATIONALE=$(echo "$WAVE_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin).get('rationale',''))")
        WAVE_ID=$(echo "$WAVE_DATA" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id', $((WAVE_INDEX+1))))")

        # Filter out already-explored files
        UNEXPLORED=""
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            local_sanitized=$(sanitize_node_name "$file")
            if [ ! -f "$NODES_DIR/${local_sanitized}.json" ]; then
                UNEXPLORED="$UNEXPLORED
$file"
            fi
        done <<< "$WAVE_FILES"
        UNEXPLORED=$(echo "$UNEXPLORED" | sed '/^$/d')

        if [ -n "$UNEXPLORED" ]; then
            WAVE_FILES="$UNEXPLORED"
            break
        fi

        WAVE_INDEX=$((WAVE_INDEX + 1))
    done

    if [ -z "$WAVE_FILES" ] || [ "$WAVE_INDEX" -ge "$NUM_WAVES" ]; then
        echo -e "${GREEN}All waves explored. Done.${NC}"
        break
    fi

    WAVE_FILE_COUNT=$(echo "$WAVE_FILES" | wc -l | tr -d ' ')
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo -e "${PURPLE}════════════════════ WAVE $WAVE_ID ($WAVE_INDEX/$NUM_WAVES) ════════════════════${NC}"
    echo -e "${BLUE}[$TIMESTAMP]${NC}"
    echo -e "  Files: $WAVE_FILE_COUNT"
    echo -e "  Rationale: $WAVE_RATIONALE"
    echo ""

    # Build exploration prompt for this wave
    EXPLORE_CONTENT=$(cat "$EXPLORE_PROMPT")
    SCOPE_JSON=$(cat "$SCOPE_FILE")
    CGC_GRAPH=""
    [ -f "$CGC_GRAPH_FILE" ] && CGC_GRAPH=$(cat "$CGC_GRAPH_FILE")
    PRIOR_NODES=$(consolidate_nodes)

    FULL_PROMPT="$EXPLORE_CONTENT

---

## scope.json

\`\`\`json
$SCOPE_JSON
\`\`\`

## CGC Dependency Graph

\`\`\`json
$CGC_GRAPH
\`\`\`

## Prior Wave Output (nodes from previous waves)

\`\`\`json
$PRIOR_NODES
\`\`\`

## Wave $WAVE_ID — Explore These Files

Rationale: $WAVE_RATIONALE

Files:
$WAVE_FILES
"

    LOG_FILE="$LOG_DIR/cartographer_wave_${WAVE_ID}_$(date '+%Y%m%d_%H%M%S').log"

    # --- Run agent ---
    if cd "$PROJECT_ROOT" && run_agent "$FULL_PROMPT" "$LOG_FILE"; then

        # Check which files got node output
        NEWLY_EXPLORED=0
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            local_sanitized=$(sanitize_node_name "$file")
            if [ -f "$NODES_DIR/${local_sanitized}.json" ]; then
                # Add to explored queue if not already there
                if ! grep -qxF "$file" "$QUEUE_EXPLORED" 2>/dev/null; then
                    echo "$file" >> "$QUEUE_EXPLORED"
                fi
                NEWLY_EXPLORED=$((NEWLY_EXPLORED + 1))
            fi
        done <<< "$WAVE_FILES"

        echo -e "${GREEN}Wave $WAVE_ID: $NEWLY_EXPLORED/$WAVE_FILE_COUNT files explored${NC}"

        if [ "$NEWLY_EXPLORED" -eq "$WAVE_FILE_COUNT" ]; then
            # All files in this wave explored, move to next
            WAVE_INDEX=$((WAVE_INDEX + 1))
            CONSECUTIVE_FAILURES=0
        elif [ "$NEWLY_EXPLORED" -gt 0 ]; then
            # Partial success — retry remaining files in this wave
            CONSECUTIVE_FAILURES=0
        else
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        fi

    else
        echo -e "${RED}Agent failed on wave $WAVE_ID${NC}"
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        tail -5 "$LOG_FILE" 2>/dev/null || true
    fi

    if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
        echo -e "${RED}$MAX_CONSECUTIVE_FAILURES consecutive failures — stopping.${NC}"
        break
    fi

    sleep 3
done

# ============================================================
# Update revision tracking
# ============================================================

if [ -f "$REVISION_FILE" ]; then
    CURRENT_SHA=$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
    python3 -c "
import json
with open('$REVISION_FILE') as f:
    rev = json.load(f)
rev['last_explored'] = '$CURRENT_SHA'
with open('$REVISION_FILE', 'w') as f:
    json.dump(rev, f, indent=2)
"
fi

# ============================================================
# Final banner
# ============================================================

TOTAL_DISCOVERED=$(wc -l < "$QUEUE_ALL" | tr -d ' ')
TOTAL_EXPLORED=$(wc -l < "$QUEUE_EXPLORED" | tr -d ' ')

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}              CARTOGRAPHER v2 FINISHED                          ${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Files explored:   $TOTAL_EXPLORED / $TOTAL_DISCOVERED"
echo -e "  Waves:            $((WAVE_INDEX + 1)) / $NUM_WAVES"
echo -e "  Output:           $EXPLORATION_DIR/"
echo ""
