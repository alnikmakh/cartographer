#!/bin/bash
#
# extract.sh — Wrap repomix to produce structural skeleton for pre-phase analysis
#
# Usage:
#   ./cartographer/prephase/extract.sh "src/auth/**,src/session/**"
#   ./cartographer/prephase/extract.sh "packages/billing/**" --ignore "**/*.css"
#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/structure.xml"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <include-patterns> [--ignore <ignore-patterns>]"
    echo ""
    echo "Examples:"
    echo "  $0 \"src/auth/**,src/session/**\""
    echo "  $0 \"packages/billing/**\" --ignore \"**/*.css\""
    exit 1
fi

INCLUDE="$1"
shift

# Default ignores
DEFAULT_IGNORE="**/*_test.go,**/*.test.ts,**/*.test.js,**/*.spec.ts,**/*.spec.js,**/node_modules/**,**/vendor/**,**/*.md,**/testdata/**,**/__tests__/**,**/__mocks__/**"

IGNORE="$DEFAULT_IGNORE"

# Parse optional --ignore override
if [ "${1:-}" = "--ignore" ] && [ -n "${2:-}" ]; then
    IGNORE="$DEFAULT_IGNORE,$2"
fi

echo "Extracting structural skeleton..."
echo "  Include: $INCLUDE"
echo "  Ignore:  $IGNORE"
echo "  Output:  $OUTPUT"
echo ""

npx repomix \
    --include "$INCLUDE" \
    --ignore "$IGNORE" \
    --compress \
    --remove-comments \
    --style xml \
    -o "$OUTPUT"

echo ""
echo "Done. Output: $OUTPUT"
