#!/usr/bin/env bash
#
# cross-synthesize.sh — Cross-scope Opus synthesis
#
# Collects all scope-manifest.json + findings.md files from explored scopes,
# builds the cross-scope analysis prompt, and runs Opus to produce
# architecture.md.
#
# Usage:
#   ./cross-synthesize.sh /path/to/source/root
#   CROSS_MODEL=opus ./cross-synthesize.sh /path/to/source/root
#
# Expects:
#   cartographer/prephase/scopes/<slug>/cartographer/exploration/
#     to contain scope-manifest.json and findings.md for each scope
#
# Output:
#   cartographer/exploration/architecture.md
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROSS_SCOPE_PROMPT="$SCRIPT_DIR/CROSS_SCOPE_PROMPT.md"
MODEL="${CROSS_MODEL:-opus}"
PROVIDER="${PROVIDER:-claude}"

SOURCE_ROOT="${1:-}"
if [[ -z "$SOURCE_ROOT" ]]; then
    echo "Usage: ./cross-synthesize.sh /path/to/source/root"
    echo ""
    echo "Collects scope-manifest.json and findings.md from all explored"
    echo "scopes and runs Opus cross-scope synthesis."
    exit 1
fi
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"

if [[ ! -f "$CROSS_SCOPE_PROMPT" ]]; then
    echo "Error: CROSS_SCOPE_PROMPT.md not found at $CROSS_SCOPE_PROMPT"
    exit 1
fi

# --- Collect scope data ---

echo "Collecting scope data..."

SCOPES_DIR="$SCRIPT_DIR/prephase/scopes"
MANIFESTS=""
FINDINGS=""
SCOPE_COUNT=0

# Look for scope-manifest.json in multiple locations:
# 1. prephase/scopes/<slug>/cartographer/exploration/
# 2. prephase/scopes/<slug>/exploration/
# 3. exploration/ (single-scope mode)

collect_scope_data() {
    local manifest_path="$1"
    local dir=$(dirname "$manifest_path")
    local findings_path="$dir/findings.md"
    local scope_name=$(basename "$(dirname "$(dirname "$dir")")" 2>/dev/null || basename "$dir")

    if [[ ! -f "$findings_path" ]]; then
        echo "  Warning: findings.md not found for scope at $dir, skipping"
        return
    fi

    SCOPE_COUNT=$((SCOPE_COUNT + 1))

    MANIFESTS="$MANIFESTS
### Scope: $scope_name

\`\`\`json
$(cat "$manifest_path")
\`\`\`
"

    FINDINGS="$FINDINGS
### Scope: $scope_name

$(cat "$findings_path")

---
"
}

# Search for manifests
if [[ -d "$SCOPES_DIR" ]]; then
    while IFS= read -r manifest; do
        [ -z "$manifest" ] && continue
        collect_scope_data "$manifest"
    done < <(find "$SCOPES_DIR" -name "scope-manifest.json" -type f 2>/dev/null | sort)
fi

# Also check main exploration dir (for single-scope or consolidated runs)
if [[ -f "$SCRIPT_DIR/exploration/scope-manifest.json" ]]; then
    collect_scope_data "$SCRIPT_DIR/exploration/scope-manifest.json"
fi

if [[ $SCOPE_COUNT -eq 0 ]]; then
    echo "Error: no scope-manifest.json files found."
    echo "Run per-scope synthesis first: ./synthesize.sh /path/to/source/root"
    exit 1
fi

echo "  Found $SCOPE_COUNT scopes"
echo "  Model: $MODEL"
echo "  Provider: $PROVIDER"
echo ""

# --- CGC cross-scope graph ---

CGC_CROSS=""
if command -v cgc &>/dev/null; then
    echo "Extracting cross-scope CGC edges..."
    CGC_CROSS=$(cgc analyze deps "$SOURCE_ROOT" 2>/dev/null || echo '{"note": "cgc cross-scope query failed"}')
fi

# --- Build prompt ---

PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<PROMPT_EOF
$(cat "$CROSS_SCOPE_PROMPT")

---

## Scope Manifests

$MANIFESTS

## Scope Findings

$FINDINGS

## CGC Cross-Scope Graph

\`\`\`json
$CGC_CROSS
\`\`\`
PROMPT_EOF

# --- Run cross-scope synthesis ---

OUTPUT_DIR="$SCRIPT_DIR/exploration"
mkdir -p "$OUTPUT_DIR"
OUTPUT="$OUTPUT_DIR/architecture.md"
LOG="$SCRIPT_DIR/cross-synthesis.log"

echo "Running cross-scope synthesis with Opus..."

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
        CURSOR_CMD="${CURSOR_CMD:-agent}"
        if ! command -v "$CURSOR_CMD" &>/dev/null; then
            echo "Error: $CURSOR_CMD not found."
            exit 1
        fi
        (cd "$SOURCE_ROOT" && $CURSOR_CMD -p --output-format text -m "$MODEL" \
            < "$PROMPT_FILE") > "$OUTPUT" 2>"$LOG"
        ;;
    *)
        echo "Error: unsupported provider '$PROVIDER'"
        echo "Supported: claude, cursor"
        exit 1
        ;;
esac

rm -f "$PROMPT_FILE"

# --- Update revision tracking ---

# Mark cross-scope revision in all scope revision files
CURRENT_SHA=$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
while IFS= read -r rev_file; do
    [ -z "$rev_file" ] && continue
    python3 -c "
import json
with open('$rev_file') as f:
    rev = json.load(f)
rev['cross_scope_revision'] = '$CURRENT_SHA'
with open('$rev_file', 'w') as f:
    json.dump(rev, f, indent=2)
" 2>/dev/null || true
done < <(find "$SCRIPT_DIR" -name "revision.json" -type f 2>/dev/null)

# --- Report ---

LINES=$(wc -l < "$OUTPUT")
echo ""
echo "Cross-scope synthesis complete:"
echo "  architecture.md: $LINES lines → $OUTPUT"
echo "  Scopes analyzed: $SCOPE_COUNT"
