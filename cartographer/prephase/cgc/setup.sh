#!/bin/bash
#
# setup.sh — Index a codebase with CodeGraphContext
#
# Usage:
#   ./cartographer/prephase/cgc/setup.sh <repo-path>
#   ./cartographer/prephase/cgc/setup.sh /path/to/project
#

set -e
set -o pipefail

REPO_PATH="${1:?Usage: setup.sh <repo-path>}"

if [ ! -d "$REPO_PATH" ]; then
    echo "Error: directory not found: $REPO_PATH"
    exit 1
fi

# Check cgc is installed
if ! command -v cgc &>/dev/null; then
    echo "Error: cgc CLI not found."
    echo ""
    echo "Install with:"
    echo "  pip install codegraphcontext"
    echo ""
    echo "Verify with:"
    echo "  cgc --version"
    exit 1
fi

echo "Indexing with CodeGraphContext..."
echo "  Repo: $REPO_PATH"
echo ""

cgc index "$REPO_PATH"

echo ""
echo "Verifying index..."

# Smoke test — list indexed repos to confirm it worked
cgc list

echo ""
echo "Stats:"
cgc stats

echo ""
echo "Indexing complete. Run cgc/auto.sh to start the pre-phase."
