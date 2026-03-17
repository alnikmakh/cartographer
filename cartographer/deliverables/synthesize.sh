#!/usr/bin/env bash
#
# synthesize.sh — Run source-verified synthesis on explored scope
#
# Takes cartographer exploration output (nodes/, edges/, index.json)
# and produces findings.md by running an Opus agent that reads both
# the structured data and actual source files.
#
# Usage:
#   ./synthesize.sh /path/to/source/root
#   SYNTH_MODEL=sonnet ./synthesize.sh /path/to/source/root
#   PROVIDER=cursor ./synthesize.sh /path/to/source/root
#
# Expects:
#   cartographer/exploration/ to contain scope.json, index.json, nodes/, edges/
#
# Output:
#   cartographer/exploration/findings.md
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPLORATION_DIR="${EXPLORATION_DIR:-$SCRIPT_DIR/exploration}"
SYNTHESIS_PROMPT="$SCRIPT_DIR/SYNTHESIS_PROMPT.md"
MODEL="${SYNTH_MODEL:-opus}"
PROVIDER="${PROVIDER:-claude}"

SOURCE_ROOT="${1:-}"
if [[ -z "$SOURCE_ROOT" ]]; then
    echo "Usage: ./synthesize.sh /path/to/source/root"
    echo ""
    echo "The source root is the directory containing the files listed in"
    echo "exploration/index.json. The synthesis agent reads these files to"
    echo "verify claims and get real signatures."
    exit 1
fi
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"

# --- Validate ---

for f in "$SYNTHESIS_PROMPT" "$EXPLORATION_DIR/scope.json" "$EXPLORATION_DIR/index.json"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: $(basename "$f") not found at $f"
        exit 1
    fi
done

if [[ ! -d "$EXPLORATION_DIR/nodes" ]] || [[ -z "$(ls "$EXPLORATION_DIR/nodes/" 2>/dev/null)" ]]; then
    echo "Error: no node files in $EXPLORATION_DIR/nodes/"
    echo "Run exploration first: ./explore.sh --init && ./explore.sh"
    exit 1
fi

# --- Consolidate nodes and edges ---

echo "Consolidating exploration data..."

NODES_JSON=$(python3 -c "
import json, glob, sys
nodes = []
for f in sorted(glob.glob('$EXPLORATION_DIR/nodes/*.json')):
    with open(f) as fh:
        nodes.append(json.load(fh))
json.dump(nodes, sys.stdout, indent=2)
")

EDGES_JSON=$(python3 -c "
import json, glob, sys
edges = []
for f in sorted(glob.glob('$EXPLORATION_DIR/edges/*.json')):
    with open(f) as fh:
        edges.append(json.load(fh))
json.dump(edges, sys.stdout, indent=2)
")

SCOPE_JSON=$(cat "$EXPLORATION_DIR/scope.json")
INDEX_JSON=$(cat "$EXPLORATION_DIR/index.json")

# Build file path listing for source access
FILE_PATHS=$(python3 -c "
import json, sys
with open('$EXPLORATION_DIR/index.json') as f:
    index = json.load(f)
for path in sorted(index.keys()):
    print('- $SOURCE_ROOT/' + path)
")

NODE_COUNT=$(python3 -c "import json,glob; print(len(glob.glob('$EXPLORATION_DIR/nodes/*.json')))")
EDGE_COUNT=$(python3 -c "import json,glob; print(len(glob.glob('$EXPLORATION_DIR/edges/*.json')))")

echo "  Nodes:    $NODE_COUNT"
echo "  Edges:    $EDGE_COUNT"
echo "  Source:   $SOURCE_ROOT"
echo "  Model:    $MODEL"
echo "  Provider: $PROVIDER"
echo ""

# --- Build prompt ---

PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<PROMPT_EOF
$(cat "$SYNTHESIS_PROMPT")

## Source Code Access

You have access to read source files. The source root is:
\`$SOURCE_ROOT\`

Files in scope (use these absolute paths with your Read tool):
$FILE_PATHS

Read these files to verify claims, get real signatures, and trace
actual data flows. Start with the seed file, then interfaces, then
files with behavioral claims in the nodes data.

---

## scope.json

\`\`\`json
$SCOPE_JSON
\`\`\`

## index.json

\`\`\`json
$INDEX_JSON
\`\`\`

## Nodes (consolidated)

\`\`\`json
$NODES_JSON
\`\`\`

## Edges (consolidated)

\`\`\`json
$EDGES_JSON
\`\`\`
PROMPT_EOF

# --- Run synthesis ---

OUTPUT="$EXPLORATION_DIR/findings.md"
LOG="$SCRIPT_DIR/synthesis.log"

echo "Running synthesis..."

case "$PROVIDER" in
    claude)
        claude -p \
            --model "$MODEL" \
            --output-format text \
            --tools "Read" \
            --add-dir "$SOURCE_ROOT" \
            --allowedTools "Read" \
            < "$PROMPT_FILE" > "$OUTPUT" 2>"$LOG"
        ;;
    cursor)
        # Cursor has no --tools/--allowedTools/--add-dir flags.
        # Run from SOURCE_ROOT so the agent has natural file access.
        # The synthesis prompt already instructs "only read, never write."
        CURSOR_CMD="${CURSOR_CMD:-agent}"
        if ! command -v "$CURSOR_CMD" &>/dev/null; then
            echo "Error: $CURSOR_CMD not found. Install Cursor CLI: https://cursor.com/cli"
            exit 1
        fi
        (cd "$SOURCE_ROOT" && $CURSOR_CMD -p --output-format text -m "$MODEL" \
            < "$PROMPT_FILE") > "$OUTPUT" 2>"$LOG"
        ;;
    *)
        echo "Error: unsupported provider '$PROVIDER' for synthesis"
        echo "Supported: claude, cursor"
        exit 1
        ;;
esac

rm -f "$PROMPT_FILE"

LINES=$(wc -l < "$OUTPUT")
echo ""
echo "Synthesis complete: $LINES lines → $OUTPUT"
