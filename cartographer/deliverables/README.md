# Cartographer — Portable Pipeline

Self-contained codebase mapping pipeline. Produces architectural
documentation by exploring source files and synthesizing findings.

Designed for single-package use: point it at one package directory,
get a findings.md with architecture, data flows, boundaries, and
non-obvious behaviors — all verified against source code.

## Prerequisites

```bash
pip install codegraphcontext kuzu    # graph indexer

# AI CLI — pick one (or both)
npm install -g @anthropic-ai/claude-code  # Claude CLI (default)
# or install Cursor CLI: https://cursor.com/cli
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

## Using Cursor CLI

All three phases support Cursor CLI as an alternative provider.

```bash
# Prephase with Cursor
PROVIDER=cursor ./run.sh /path/to/your/package

# Exploration with Cursor
./explore.sh cursor
CURSOR_MODEL=sonnet-4 ./explore.sh cursor 10

# Synthesis with Cursor
PROVIDER=cursor ./synthesize.sh /path/to/source/root
```

**Cursor differences from Claude:**
- MCP: Cursor auto-discovers from `.cursor/mcp.json` (run.sh sets this up automatically)
- Synthesis: Cursor has no `--tools`/`--allowedTools` flags — relies on prompt discipline for read-only behavior
- Permissions: uses `--yolo` instead of `--dangerously-skip-permissions`
- Model names differ (e.g., `sonnet-4` vs `sonnet`)

## Environment Variables

| Variable | Used by | Default | Description |
|----------|---------|---------|-------------|
| `PROJECT_ROOT` | explore.sh | parent dir of explore.sh | Where source files live |
| `EXPLORATION_DIR` | explore.sh, synthesize.sh | `./exploration` | Where to write nodes/edges/index |
| `PROVIDER` | run.sh, synthesize.sh | claude | AI CLI provider (`claude` or `cursor`) |
| `CLAUDE_MODEL` | explore.sh | (provider default) | Model for exploration (Claude) |
| `CURSOR_MODEL` | explore.sh | (provider default) | Model for exploration (Cursor) |
| `SYNTH_MODEL` | synthesize.sh | opus | Model for synthesis |
| `SOURCE_ROOT` | synthesize.sh | (required arg) | Same as PROJECT_ROOT |
| `CURSOR_CMD` | all scripts | agent | Cursor CLI command name |
| `CLAUDE_CMD` | explore.sh | claude | Claude CLI command name |

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

## Providers

| Phase | Supported Providers | Notes |
|-------|-------------------|-------|
| Prephase | claude, cursor | MCP required for CGC graph queries |
| Exploration | claude, codex, gemini, copilot, cursor | Any provider works |
| Synthesis | claude, cursor | Claude preferred (tool restrictions) |

## Models

| Phase | Default | Override | Notes |
|-------|---------|----------|-------|
| Prephase | Opus | — | Needs MCP tools, architectural judgment |
| Exploration | haiku | `CLAUDE_MODEL=sonnet` / `CURSOR_MODEL=sonnet-4` | Cheap file-by-file reading |
| Synthesis | Opus | `SYNTH_MODEL=sonnet` | Source-verified, needs precision |

## Updating Prompts

If you modify prompts in the main `cartographer/` directory:

```bash
./update.sh
```

This copies the latest prompts into deliverables without touching
the local scripts (run.sh, synthesize.sh).
