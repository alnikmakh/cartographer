#!/usr/bin/env bash
set -euo pipefail

RUNS_DIR="$(cd "$(dirname "$0")/runs" && pwd)"
SYNTHESIS_PROMPT="$(cd "$(dirname "$0")/../../../" && pwd)/SYNTHESIS_PROMPT.md"
MODEL="${SYNTH_MODEL:-opus}"
SOURCE_ROOT="${SOURCE_ROOT:-/home/dev/project/tg-digest}"

if [[ ! -f "$SYNTHESIS_PROMPT" ]]; then
  echo "ERROR: SYNTHESIS_PROMPT.md not found at $SYNTHESIS_PROMPT" >&2
  exit 1
fi

synthesize_scope() {
  local slug="$1"
  local explore_dir="$RUNS_DIR/$slug/cartographer/exploration"
  local output="$RUNS_DIR/$slug/cartographer/exploration/findings.md"
  local log="$RUNS_DIR/$slug/synthesis.log"

  echo "[$slug] Starting synthesis..."

  # Consolidate nodes into a single JSON array
  local nodes_consolidated
  nodes_consolidated=$(python3 -c "
import json, glob, sys
nodes = []
for f in sorted(glob.glob('$explore_dir/nodes/*.json')):
    with open(f) as fh:
        nodes.append(json.load(fh))
json.dump(nodes, sys.stdout, indent=2)
")

  # Consolidate edges into a single JSON array
  local edges_consolidated
  edges_consolidated=$(python3 -c "
import json, glob, sys
edges = []
for f in sorted(glob.glob('$explore_dir/edges/*.json')):
    with open(f) as fh:
        edges.append(json.load(fh))
json.dump(edges, sys.stdout, indent=2)
")

  local scope_json
  scope_json=$(cat "$explore_dir/scope.json")

  local index_json
  index_json=$(cat "$explore_dir/index.json")

  # Build file path listing from index.json for source access
  local file_paths
  file_paths=$(python3 -c "
import json, sys
with open('$explore_dir/index.json') as f:
    index = json.load(f)
for path in sorted(index.keys()):
    print('- $SOURCE_ROOT/' + path)
")

  # Write prompt to temp file (avoids shell escaping issues with pipe)
  local prompt_file
  prompt_file=$(mktemp)
  cat > "$prompt_file" <<PROMPT_EOF
$(cat "$SYNTHESIS_PROMPT")

## Source Code Access

You have access to read source files. The source root is:
\`$SOURCE_ROOT\`

Files in scope (use these absolute paths with your Read tool):
$file_paths

Read these files to verify claims, get real signatures, and trace
actual data flows. Start with the seed file, then interfaces, then
files with behavioral claims in the nodes data.

---

## scope.json

\`\`\`json
$scope_json
\`\`\`

## index.json

\`\`\`json
$index_json
\`\`\`

## Nodes (consolidated)

\`\`\`json
$nodes_consolidated
\`\`\`

## Edges (consolidated)

\`\`\`json
$edges_consolidated
\`\`\`
PROMPT_EOF

  # Run synthesis — only Read tool available (no Write/Bash/Edit)
  # Agent reads source for verification, outputs findings to stdout
  claude -p \
    --model "$MODEL" \
    --output-format text \
    --tools "Read" \
    --add-dir "$SOURCE_ROOT" \
    --allowedTools "Read" \
    < "$prompt_file" > "$output" 2>"$log"

  local status=$?
  rm -f "$prompt_file"

  if [[ $status -eq 0 ]]; then
    local lines
    lines=$(wc -l < "$output")
    echo "[$slug] Done — $lines lines → $output"
  else
    echo "[$slug] FAILED (exit $status) — see $log" >&2
  fi
  return $status
}

# Launch all scopes in parallel
pids=()
slugs=()
for scope_dir in "$RUNS_DIR"/*/; do
  slug=$(basename "$scope_dir")
  [[ -d "$scope_dir/cartographer/exploration/nodes" ]] || continue
  synthesize_scope "$slug" &
  pids+=($!)
  slugs+=("$slug")
done

echo "Launched ${#pids[@]} synthesis jobs"
echo "Model: $MODEL | Source: $SOURCE_ROOT"
echo ""

# Wait and collect results
failed=0
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    echo "FAILED: ${slugs[$i]}" >&2
    ((failed++))
  fi
done

echo ""
echo "=== Synthesis Complete ==="
echo "Total: ${#pids[@]}  Failed: $failed"
echo ""

# Summary table
for scope_dir in "$RUNS_DIR"/*/; do
  slug=$(basename "$scope_dir")
  findings="$scope_dir/cartographer/exploration/findings.md"
  if [[ -f "$findings" ]]; then
    lines=$(wc -l < "$findings")
    printf "%-25s %4d lines\n" "$slug" "$lines"
  else
    printf "%-25s MISSING\n" "$slug"
  fi
done
