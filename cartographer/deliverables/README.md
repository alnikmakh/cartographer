# Cartographer — Portable Pipeline

Self-contained codebase mapping pipeline. Produces architectural
documentation by exploring source files and synthesizing findings.

Designed for single-package use: point it at one package directory,
get a findings.md with architecture, data flows, boundaries, and
non-obvious behaviors — all verified against source code.

## Prerequisites

```bash
pip install codegraphcontext kuzu    # graph indexer
npm install -g @anthropic-ai/claude-code  # AI CLI
```

## Quick Start

```bash
# 1. Index your package
cgc index /path/to/your/package

# 2. Run prephase (produces scope.json)
./run.sh /path/to/your/package

# 3. Review and pick a scope
cat cartographer/prephase/scopes/*/scope.json

# 4. Copy scope into exploration dir
mkdir -p cartographer/exploration
cp cartographer/prephase/scopes/<slug>/scope.json cartographer/exploration/

# 5. Initialize and run exploration (Haiku by default)
./explore.sh --init
CLAUDE_MODEL=haiku ./explore.sh

# 6. Run synthesis (Opus by default, reads source for verification)
./synthesize.sh /path/to/your/package

# 7. Read the output
cat cartographer/exploration/findings.md
```

## Single-Package Workflow

For a single package within a monorepo:

```bash
# Point everything at one package
PACKAGE=/path/to/monorepo/packages/my-service

cgc index "$PACKAGE"
./run.sh "$PACKAGE"

# The prephase may produce multiple slices within the package.
# For a single scope covering the whole package, you can write
# scope.json manually:
mkdir -p exploration
cat > exploration/scope.json << 'EOF'
{
  "seed": "src/index.ts",
  "boundaries": {
    "explore_within": ["src/**"],
    "boundary_packages": []
  },
  "hints": []
}
EOF

# PROJECT_ROOT tells explore.sh where the source files are
PROJECT_ROOT="$PACKAGE" ./explore.sh --init
PROJECT_ROOT="$PACKAGE" CLAUDE_MODEL=haiku ./explore.sh
./synthesize.sh "$PACKAGE"
```

## Environment Variables

| Variable | Used by | Default | Description |
|----------|---------|---------|-------------|
| `PROJECT_ROOT` | explore.sh | parent dir of explore.sh | Where source files live |
| `EXPLORATION_DIR` | explore.sh | `./exploration` | Where to write nodes/edges/index |
| `CLAUDE_MODEL` | explore.sh | (provider default) | Model for exploration |
| `SYNTH_MODEL` | synthesize.sh | opus | Model for synthesis |
| `SOURCE_ROOT` | synthesize.sh | (required arg) | Same as PROJECT_ROOT |

## File Structure

```
deliverables/
├── README.md              ← this file
├── update.sh              ← sync prompts from cartographer source
├── run.sh                 ← prephase: CGC index + auto scope detection
├── explore.sh             ← exploration loop (drives AI agent per batch)
├── synthesize.sh          ← synthesis: structured data + source → findings.md
├── PROMPT.md              ← exploration agent instructions
├── SYNTHESIS_PROMPT.md    ← synthesis agent instructions
├── prephase/
│   ├── AUTO_PROMPT.md     ← auto prephase instructions
│   ├── PROMPT.md          ← interactive prephase instructions
│   └── mcp.json           ← MCP config for CGC
└── exploration/           ← created at runtime
    ├── scope.json
    ├── queue_all.txt
    ├── queue_explored.txt
    ├── index.json
    ├── findings.md         ← final output
    ├── nodes/*.json
    └── edges/*.json
```

## Models

| Phase | Default | Override | Notes |
|-------|---------|----------|-------|
| Prephase | Opus | — | Needs MCP tools, architectural judgment |
| Exploration | haiku | `CLAUDE_MODEL=sonnet` | Cheap file-by-file reading |
| Synthesis | Opus | `SYNTH_MODEL=sonnet` | Source-verified, needs precision |

## Updating Prompts

If you modify prompts in the main `cartographer/` directory:

```bash
./update.sh
```

This copies the latest prompts into deliverables without touching
the local scripts (run.sh, synthesize.sh).
