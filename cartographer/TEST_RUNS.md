# How to Run Cartographer v2

Cartographer v2 uses a wave-based pipeline: CGC graph for structure,
Sonnet for per-file analysis, Opus for cross-cutting review.

## Full Pipeline (Recommended)

The `run.sh` orchestrator runs the complete pipeline:

```bash
# Full generation — prephase + explore + synthesize + cross-scope
./cartographer/run.sh /path/to/source/root

# Incremental update — only re-explore changed files
./cartographer/run.sh /path/to/source/root --incremental
```

Environment variables:
```bash
PROVIDER=claude          # or cursor
CLAUDE_MODEL=sonnet      # exploration + synthesis model (default: sonnet)
CROSS_MODEL=opus         # cross-scope model (default: opus)
SKIP_PREPHASE=1          # reuse existing scopes
SKIP_CROSS=1             # skip cross-scope synthesis
SCOPE=storage            # only process one scope (debugging)
```

## Manual Step-by-Step

### 1. Index the codebase

```bash
pip install codegraphcontext kuzu
cgc index /path/to/source/root
```

### 2. Run prephase (Opus scope determination)

```bash
./cartographer/prephase/cgc/auto.sh
```

Produces `cartographer/prephase/scopes/<slug>/scope.json` for each scope.

### 3. Set up exploration

Copy a scope.json into the exploration directory:

```bash
mkdir -p cartographer/exploration
cp cartographer/prephase/scopes/<slug>/scope.json cartographer/exploration/
```

### 4. Initialize and explore

```bash
./cartographer/explore.sh --init    # validates scope, extracts CGC graph, creates revision.json
./cartographer/explore.sh           # wave planning + wave execution (Sonnet)
```

The explore script:
1. Runs Sonnet to plan exploration waves from CGC graph (`waves.json`)
2. Executes waves sequentially, accumulating context
3. Each wave produces v2 nodes (role, contracts, effects, state, observations) and semantic edges

Override model: `CLAUDE_MODEL=sonnet ./cartographer/explore.sh` (sonnet is already the default).

### 5. Synthesize

```bash
./cartographer/synthesize.sh /path/to/source/root
```

Produces:
- `exploration/findings.md` — architectural narrative
- `exploration/scope-manifest.json` — machine-readable summary for cross-scope

Override model: `SYNTH_MODEL=sonnet` (default) or `SYNTH_MODEL=opus`.

### 6. Cross-scope synthesis (multi-scope only)

```bash
./cartographer/cross-synthesize.sh /path/to/source/root
```

Collects all scope-manifest.json + findings.md files, runs Opus for
adversarial cross-cutting analysis. Produces `exploration/architecture.md`.

### 7. Incremental update

After making changes to the source:

```bash
./cartographer/explore.sh --incremental      # re-explore changed files only
./cartographer/synthesize.sh --incremental /path/to/source/root  # re-synthesize if stale
```

## Writing scope.json Manually

All three fields required — `--init` validates their presence.

```json
{
  "seed": "src/core/main.ts",
  "boundaries": {
    "explore_within": ["src/core/**"],
    "boundary_packages": ["src/utils", "src/db"]
  },
  "hints": ["Uses repository pattern", "Heavy use of generics"]
}
```

**seed** — any file in the slice. Documents intent.

**explore_within** — directory globs the agent will fully explore. Use `**` suffix.

**boundary_packages** — sibling packages imported but not fully explored.
The agent records boundary edges but doesn't read source in these packages.

**hints** — optional observations for the explorer to watch for.

## Directory Layout

After `--init`:

```
exploration/
├── scope.json          ← your input
├── queue_all.txt       ← all in-scope files
├── queue_explored.txt  ← explored files (grows during exploration)
├── waves.json          ← Sonnet-planned exploration order
├── cgc_graph.json      ← AST dependency data from CGC
├── revision.json       ← SHA tracking for incremental mode
├── findings.md         ← synthesis output
├── scope-manifest.json ← machine-readable manifest
├── nodes/              ← v2 node files (role, contracts, observations)
└── edges/              ← v2 edge files (semantic, data_flow, coupling)
```

## v2 Node Schema

```json
{
  "path": "src/auth/service.ts",
  "role": "orchestrator",
  "summary": "Coordinates JWT validation and RBAC checks",
  "contracts": {
    "requires": ["JWT_SECRET env var"],
    "guarantees": ["Returns AuthContext or throws — never partial"]
  },
  "effects": ["Redis read/write per request"],
  "state": "LRU cache, 5-min TTL",
  "observations": [
    { "kind": "risk", "text": "Revoked tokens valid up to 5 min", "loc": "service.ts:89" }
  ]
}
```

## v2 Edge Schema

```json
{
  "from": "src/auth/service.ts",
  "to": "src/auth/jwt.ts",
  "semantic": "delegates token parsing",
  "data_flow": "raw JWT → decoded Claims",
  "coupling": "direct"
}
```

## Inspecting Results

```bash
# Progress
wc -l < exploration/queue_all.txt       # total files
wc -l < exploration/queue_explored.txt  # explored so far

# Pending files
comm -23 <(sort exploration/queue_all.txt) <(sort exploration/queue_explored.txt)

# Read a v2 node
cat exploration/nodes/src__auth__service.ts.json | python3 -m json.tool

# Wave plan
cat exploration/waves.json | python3 -m json.tool

# Revision state
cat exploration/revision.json | python3 -m json.tool
```

## Models

| Phase | Default | Override | Notes |
|-------|---------|----------|-------|
| Prephase | Opus | — | Cross-cutting judgment, MCP graph queries |
| Wave planning | Sonnet | `CLAUDE_MODEL=X` | Graph analysis only, no file reading |
| Exploration | Sonnet | `CLAUDE_MODEL=X` | Reads full source, produces rich nodes |
| Per-scope synthesis | Sonnet | `SYNTH_MODEL=X` | Rich v2 input compensates for smaller model |
| Cross-scope synthesis | Opus | `CROSS_MODEL=X` | Adversarial cross-cutting analysis |

Opus is used for exactly 2 calls (prephase + cross-scope) regardless of scope count.
