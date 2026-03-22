# Cartographer v2 — Portable Pipeline

Self-contained codebase mapping pipeline. Produces architectural
documentation by exploring source files in intelligently-ordered waves
and synthesizing findings — all verified against source code.

## Pipeline

```
CGC index (instant)
  → Opus prephase: scope determination via dependency graph
  → Sonnet wave planning: orders files using CGC graph
  → Sonnet wave exploration: reads full source, accumulates context
  → Sonnet per-scope synthesis → findings.md + scope-manifest.json
  → Opus cross-scope synthesis → architecture.md
```

Opus is used for exactly 2 calls (prephase + cross-scope). Sonnet handles
everything else.

## Prerequisites

```bash
pip install codegraphcontext kuzu    # graph indexer

# AI CLI — pick one (or both)
npm install -g @anthropic-ai/claude-code  # Claude CLI (default)
# or install Cursor CLI: https://cursor.com/cli
```

## Quick Start

```bash
# 1. Full pipeline — prephase + explore + synthesize + cross-scope
./cartographer/run.sh /path/to/source/root

# 2. Read the output
cat cartographer/exploration/findings.md           # per-scope narrative
cat cartographer/exploration/scope-manifest.json   # machine-readable
cat cartographer/exploration/architecture.md       # cross-scope analysis
```

## Single-Package Workflow

For a single package (or to skip prephase):

```bash
PACKAGE=/path/to/your/package

# 1. Index
cgc index "$PACKAGE"

# 2. Write scope.json
mkdir -p cartographer/exploration
cat > cartographer/exploration/scope.json << 'EOF'
{
  "seed": "src/index.ts",
  "boundaries": {
    "explore_within": ["src/**"],
    "boundary_packages": []
  },
  "hints": []
}
EOF

# 3. Initialize (validates scope, extracts CGC graph)
PROJECT_ROOT="$PACKAGE" ./cartographer/explore.sh --init

# 4. Explore (Sonnet wave-based)
PROJECT_ROOT="$PACKAGE" ./cartographer/explore.sh

# 5. Synthesize (Sonnet + source verification)
./cartographer/synthesize.sh "$PACKAGE"

# 6. Read output
cat cartographer/exploration/findings.md
cat cartographer/exploration/scope-manifest.json
```

## Incremental Updates

After modifying source files:

```bash
# Re-explore only changed files, re-synthesize if needed
./cartographer/run.sh /path/to/source/root --incremental
```

Or manually:
```bash
./cartographer/explore.sh --incremental
./cartographer/synthesize.sh --incremental /path/to/source/root
```

## Using Cursor CLI

All phases support Cursor CLI as an alternative provider.

```bash
# Full pipeline
PROVIDER=cursor ./cartographer/run.sh /path/to/source/root

# Individual phases
PROVIDER=cursor ./cartographer/explore.sh cursor
PROVIDER=cursor ./cartographer/synthesize.sh /path/to/source/root
```

**Cursor differences from Claude:**
- MCP: auto-discovers from `.cursor/mcp.json`
- Synthesis: no `--tools`/`--allowedTools` flags — relies on prompt discipline
- Permissions: uses `--yolo` instead of `--dangerously-skip-permissions`
- Model names differ (e.g., `sonnet-4` vs `sonnet`)

## Environment Variables

| Variable | Used by | Default | Description |
|----------|---------|---------|-------------|
| `PROJECT_ROOT` | explore.sh | parent of script | Where source files live (for file discovery) |
| `SOURCE_ROOT` | explore.sh | PROJECT_ROOT | Git repo for incremental SHA tracking |
| `EXPLORATION_DIR` | explore.sh, synthesize.sh | `./exploration` | Output directory for nodes/edges/findings |
| `PROVIDER` | all scripts | claude | AI CLI provider (`claude` or `cursor`) |
| `CLAUDE_MODEL` | explore.sh | sonnet | Model for wave planning + exploration |
| `SYNTH_MODEL` | synthesize.sh | sonnet | Model for per-scope synthesis |
| `CROSS_MODEL` | cross-synthesize.sh | opus | Model for cross-scope synthesis |
| `SKIP_PREPHASE` | run.sh | — | Set to `1` to skip prephase |
| `SKIP_CROSS` | run.sh | — | Set to `1` to skip cross-scope synthesis |
| `SCOPE` | run.sh | — | Process only this scope slug |

## Output Files

```
exploration/
├── scope.json              ← input: exploration parameters
├── waves.json              ← Sonnet-planned exploration order
├── cgc_graph.json          ← AST dependency data from CGC
├── revision.json           ← SHA tracking for incremental mode
├── queue_all.txt           ← all in-scope files
├── queue_explored.txt      ← explored files
├── findings.md             ← architectural narrative
├── scope-manifest.json     ← machine-readable manifest
├── architecture.md         ← cross-scope analysis (multi-scope only)
├── nodes/                  ← v2 node files
│   └── <sanitized>.json    ← role, contracts, effects, state, observations
└── edges/                  ← v2 edge files
    └── <sanitized>.edges.json  ← semantic, data_flow, coupling
```

## Providers

| Phase | Supported | Notes |
|-------|-----------|-------|
| Prephase | claude, cursor | MCP required for CGC graph queries |
| Wave planning | claude, codex, gemini, copilot, cursor | Any provider |
| Exploration | claude, codex, gemini, copilot, cursor | Any provider |
| Synthesis | claude, cursor | Claude preferred (tool restrictions) |
| Cross-scope | claude, cursor | Opus recommended |

## Models

| Phase | Default | Override | Notes |
|-------|---------|----------|-------|
| Prephase | Opus | — | Cross-cutting judgment, MCP tools |
| Wave planning | Sonnet | `CLAUDE_MODEL=X` | Graph analysis only |
| Exploration | Sonnet | `CLAUDE_MODEL=X` | Full source reading |
| Per-scope synthesis | Sonnet | `SYNTH_MODEL=X` | Rich v2 input compensates |
| Cross-scope synthesis | Opus | `CROSS_MODEL=X` | Adversarial analysis |

## Updating Prompts

If you modify prompts in the main `cartographer/` directory:

```bash
./update.sh
```
