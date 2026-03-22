#!/usr/bin/env bash
#
# synthesize.sh — v2 per-scope synthesis with Sonnet
#
# Takes cartographer v2 exploration output (nodes/, edges/ with rich schema)
# and produces:
#   - findings.md (architectural narrative)
#   - scope-manifest.json (machine-readable, for cross-scope synthesis)
#
# Usage:
#   ./synthesize.sh /path/to/source/root
#   SYNTH_MODEL=sonnet ./synthesize.sh /path/to/source/root
#   ./synthesize.sh --incremental /path/to/source/root
#
# Expects:
#   cartographer/exploration/ to contain scope.json, nodes/, edges/
#
# Output:
#   cartographer/exploration/findings.md
#   cartographer/exploration/scope-manifest.json
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPLORATION_DIR="${EXPLORATION_DIR:-$SCRIPT_DIR/exploration}"
SYNTHESIS_PROMPT="$SCRIPT_DIR/SYNTHESIS_PROMPT.md"
# v2 default: Sonnet for per-scope synthesis (was Opus in v1)
MODEL="${SYNTH_MODEL:-sonnet}"
PROVIDER="${PROVIDER:-claude}"

# Handle --incremental flag
INCREMENTAL=false
if [[ "${1:-}" = "--incremental" ]]; then
    INCREMENTAL=true
    shift
fi

SOURCE_ROOT="${1:-}"
if [[ -z "$SOURCE_ROOT" ]]; then
    echo "Usage: ./synthesize.sh [--incremental] /path/to/source/root"
    echo ""
    echo "The source root is the directory containing the files listed in"
    echo "exploration nodes. The synthesis agent reads these files to"
    echo "verify claims and get real signatures."
    exit 1
fi
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"

# --- Validate ---

for f in "$SYNTHESIS_PROMPT" "$EXPLORATION_DIR/scope.json"; do
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

# --- Incremental check ---

REVISION_FILE="$EXPLORATION_DIR/revision.json"

if [[ "$INCREMENTAL" = true ]]; then
    if [[ ! -f "$REVISION_FILE" ]]; then
        echo "Error: revision.json not found. Run full synthesis first."
        exit 1
    fi

    LAST_SYNTH=$(python3 -c "import json; print(json.load(open('$REVISION_FILE')).get('last_synthesized') or 'none')")
    LAST_EXPLORED=$(python3 -c "import json; print(json.load(open('$REVISION_FILE')).get('last_explored') or 'none')")

    if [[ "$LAST_SYNTH" = "$LAST_EXPLORED" ]]; then
        echo "Synthesis is up to date with exploration ($LAST_SYNTH). Nothing to do."
        exit 0
    fi

    echo "Incremental synthesis: exploration=$LAST_EXPLORED, last synth=$LAST_SYNTH"
fi

# --- Consolidate nodes and edges ---

echo "Consolidating exploration data..."

NODES_JSON=$(python3 -c "
import json, glob, sys
nodes = []
for f in sorted(glob.glob('$EXPLORATION_DIR/nodes/*.json')):
    with open(f) as fh:
        try:
            nodes.append(json.load(fh))
        except json.JSONDecodeError:
            pass
json.dump(nodes, sys.stdout, indent=2)
")

EDGES_JSON=$(python3 -c "
import json, glob, sys
edges = []
for f in sorted(glob.glob('$EXPLORATION_DIR/edges/*.json')):
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
")

SCOPE_JSON=$(cat "$EXPLORATION_DIR/scope.json")

# CGC graph data (if available)
CGC_GRAPH=""
if [[ -f "$EXPLORATION_DIR/cgc_graph.json" ]]; then
    CGC_GRAPH=$(cat "$EXPLORATION_DIR/cgc_graph.json")
fi

# Build file path listing for source access
FILE_PATHS=$(python3 -c "
import json, glob, sys
nodes = []
for f in sorted(glob.glob('$EXPLORATION_DIR/nodes/*.json')):
    with open(f) as fh:
        try:
            node = json.load(fh)
            if 'path' in node:
                print('- $SOURCE_ROOT/' + node['path'])
        except json.JSONDecodeError:
            pass
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
actual data flows. Start with the seed file, then files with risk/behavior
observations, then boundary files.

---

## scope.json

\`\`\`json
$SCOPE_JSON
\`\`\`

## CGC Graph Data

\`\`\`json
$CGC_GRAPH
\`\`\`

## Nodes (consolidated v2)

\`\`\`json
$NODES_JSON
\`\`\`

## Edges (consolidated v2)

\`\`\`json
$EDGES_JSON
\`\`\`
PROMPT_EOF

# --- Run synthesis ---

OUTPUT="$EXPLORATION_DIR/findings.md"
MANIFEST="$EXPLORATION_DIR/scope-manifest.json"
LOG="$SCRIPT_DIR/synthesis.log"

echo "Running synthesis..."

case "$PROVIDER" in
    claude)
        claude -p \
            --model "$MODEL" \
            --output-format text \
            --tools "Read,Write" \
            --add-dir "$SOURCE_ROOT" \
            --allowedTools "Read,Write" \
            < "$PROMPT_FILE" > "$OUTPUT" 2>"$LOG"
        ;;
    cursor)
        CURSOR_CMD="${CURSOR_CMD:-agent}"
        if ! command -v "$CURSOR_CMD" &>/dev/null; then
            echo "Error: $CURSOR_CMD not found."
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

# --- Generate scope-manifest.json from structured data ---
# The synthesis agent may or may not Write the manifest. As a safety net,
# generate it programmatically from the rich v2 node/edge data.

if [[ ! -f "$MANIFEST" ]]; then
    echo "Generating scope-manifest.json from node/edge data..."

    python3 -c "
import json, glob, os

exploration = '$EXPLORATION_DIR'

# Load scope
with open(os.path.join(exploration, 'scope.json')) as f:
    scope = json.load(f)

seed = scope.get('seed', '')
scope_name = os.path.basename(os.path.dirname(seed)) if '/' in seed else seed

# Load all nodes
nodes = []
for f in sorted(glob.glob(os.path.join(exploration, 'nodes', '*.json'))):
    with open(f) as fh:
        try:
            nodes.append(json.load(fh))
        except json.JSONDecodeError:
            pass

# Load all edges
edges = []
for f in sorted(glob.glob(os.path.join(exploration, 'edges', '*.json'))):
    with open(f) as fh:
        try:
            data = json.load(fh)
            if isinstance(data, list):
                edges.extend(data)
            else:
                edges.append(data)
        except json.JSONDecodeError:
            pass

# Build manifest
manifest = {
    'scope': scope_name,
    'purpose': '',
    'exposes': {'types': [], 'interfaces': [], 'entry_points': []},
    'consumes': {'external': [], 'config': []},
    'cross_scope_touchpoints': [],
    'invariants': [],
    'risks': [],
    'patterns': []
}

# Extract from nodes
for node in nodes:
    role = node.get('role', '')
    contracts = node.get('contracts', {})
    observations = node.get('observations', [])

    # Entry points
    if role in ('entry-point', 'orchestrator', 'container'):
        summary = node.get('summary', '')
        if summary and not manifest['purpose']:
            manifest['purpose'] = summary

    # Contracts → config requirements
    for req in contracts.get('requires', []):
        if any(kw in req.lower() for kw in ['env', 'config', 'var', 'path', 'file']):
            if req not in manifest['consumes']['config']:
                manifest['consumes']['config'].append(req)

    # Observations
    for obs in observations:
        kind = obs.get('kind', '')
        text = obs.get('text', '')
        if kind == 'risk' and text not in manifest['risks']:
            manifest['risks'].append(text)
        elif kind == 'invariant' and text not in manifest['invariants']:
            manifest['invariants'].append(text)
        elif kind == 'pattern' and text not in manifest['patterns']:
            manifest['patterns'].append(text)

# Extract from edges
boundary_pkgs = set(scope.get('boundaries', {}).get('boundary_packages', []))
for edge in edges:
    to_path = edge.get('to', '')
    # External system edges (in brackets)
    if to_path.startswith('[') and to_path.endswith(']'):
        ext = to_path.strip('[]')
        if ext not in manifest['consumes']['external']:
            manifest['consumes']['external'].append(ext)
    # Cross-scope touchpoints
    for bp in boundary_pkgs:
        if bp and bp in to_path:
            tp = {
                'scope': bp.split('/')[-1] if '/' in bp else bp,
                'direction': 'consumes',
                'surface': edge.get('semantic', to_path),
                'coupling': edge.get('coupling', 'direct')
            }
            # Deduplicate by scope+surface
            existing = [t['scope'] + t['surface'] for t in manifest['cross_scope_touchpoints']]
            if tp['scope'] + tp['surface'] not in existing:
                manifest['cross_scope_touchpoints'].append(tp)

# Extract exposed types from entry-point/container nodes
for node in nodes:
    role = node.get('role', '')
    if role in ('container', 'entry-point', 'model'):
        contracts = node.get('contracts', {})
        for g in contracts.get('guarantees', []):
            if g not in manifest['exposes']['entry_points']:
                manifest['exposes']['entry_points'].append(g)

with open(os.path.join(exploration, 'scope-manifest.json'), 'w') as f:
    json.dump(manifest, f, indent=2)

print(f'  Generated: {len(manifest[\"risks\"])} risks, {len(manifest[\"patterns\"])} patterns, {len(manifest[\"cross_scope_touchpoints\"])} touchpoints')
"
fi

# --- Update revision tracking ---

if [[ -f "$REVISION_FILE" ]]; then
    CURRENT_SHA=$(python3 -c "import json; print(json.load(open('$REVISION_FILE')).get('last_explored', 'unknown'))")
    python3 -c "
import json
with open('$REVISION_FILE') as f:
    rev = json.load(f)
rev['last_synthesized'] = '$CURRENT_SHA'
with open('$REVISION_FILE', 'w') as f:
    json.dump(rev, f, indent=2)
"
fi

# --- Report ---

LINES=$(wc -l < "$OUTPUT")
echo ""
echo "Synthesis complete:"
echo "  findings.md:        $LINES lines → $OUTPUT"
if [[ -f "$MANIFEST" ]]; then
    echo "  scope-manifest.json: $MANIFEST"
else
    echo "  scope-manifest.json: not created (agent may not have written it)"
fi

# --- Incremental: check if cross-scope is stale ---

if [[ "$INCREMENTAL" = true ]] && [[ -f "$MANIFEST" ]]; then
    # Compare old and new manifest for cross-scope-relevant changes
    OLD_MANIFEST="$EXPLORATION_DIR/scope-manifest.json.prev"
    if [[ -f "$OLD_MANIFEST" ]]; then
        STALE=$(python3 -c "
import json
try:
    with open('$OLD_MANIFEST') as f:
        old = json.load(f)
    with open('$MANIFEST') as f:
        new = json.load(f)
    # Check if cross-scope-relevant fields changed
    for key in ['cross_scope_touchpoints', 'exposes', 'invariants']:
        if json.dumps(old.get(key)) != json.dumps(new.get(key)):
            print('stale')
            break
    else:
        print('ok')
except:
    print('stale')
")
        if [[ "$STALE" = "stale" ]]; then
            echo ""
            echo "  Cross-scope synthesis is STALE — manifest changed in cross-scope-relevant fields."
            echo "  Re-run cross-synthesize.sh to update architecture.md."
        fi
    fi
    # Save current as .prev for next incremental comparison
    cp "$MANIFEST" "$OLD_MANIFEST"
fi
