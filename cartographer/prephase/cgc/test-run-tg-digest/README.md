# CGC Pre-Phase Test Run: tg-digest

End-to-end test of the full cartographer v2 pipeline against the tg-digest
Go application (57 files, 7 internal packages + cmd).

## Target

`/home/dev/project/tg-digest` — Telegram channel digest app. Go codebase with
packages: storage, config, telegram, source (4 implementations), refresh,
summarizer, tui (Bubble Tea), and cmd/digest entrypoint.

## Prerequisites

```bash
pip install codegraphcontext kuzu
cgc index /home/dev/project/tg-digest
cgc list   # should show tg-digest
```

## How to Run

### v2 Pipeline (recommended)

```bash
# Full pipeline: prephase → wave exploration → synthesis → cross-scope
./run-all-v2.sh

# Skip prephase (reuse existing scopes)
./run-all-v2.sh --skip-prephase

# Only exploration (no synthesis)
./run-all-v2.sh --explore-only

# Only synthesis (reuse existing nodes)
./run-all-v2.sh --synthesize-only

# Incremental (re-explore changed files only)
./run-all-v2.sh --incremental
```

Override models:
```bash
EXPLORE_MODEL=sonnet ./run-all-v2.sh        # default
SYNTH_MODEL=sonnet ./run-all-v2.sh          # default
CROSS_MODEL=opus ./run-all-v2.sh            # default
PROVIDER=cursor ./run-all-v2.sh             # use Cursor CLI
```

### What the v2 pipeline does

1. **CGC Index** — indexes tg-digest with tree-sitter AST parser
2. **Prephase** — Opus queries CGC graph via MCP, identifies 7 scopes, writes scope.json files
3. **Setup** — creates isolated run dirs per scope with symlinks to tg-digest source
4. **Wave Exploration** (parallel, Sonnet) — per scope:
   - Sonnet plans exploration waves from CGC graph → `waves.json`
   - Sonnet reads full source per wave, accumulating context → v2 nodes/edges
5. **Per-scope Synthesis** (parallel, Sonnet) — produces findings.md + scope-manifest.json
6. **Cross-scope Synthesis** (Opus) — adversarial analysis → architecture.md

### v1 Pipeline (legacy)

```bash
./run-all.sh                    # v1: Haiku batch exploration
./synthesize-all.sh             # v1: Opus synthesis
```

## File Structure

```
test-run-tg-digest/
├── README.md                ← this file
├── run-all-v2.sh            ← v2 full pipeline runner
├── run-all.sh               ← v1 parallel exploration (legacy)
├── synthesize-all.sh        ← v1 parallel synthesis (legacy)
├── run.sh                   ← standalone prephase runner
├── hallucination-bug.md     ← v1 issues writeup
├── auto.log                 ← prephase session log
├── slices.json              ← prephase output
├── scopes/                  ← scope definitions (durable)
│   ├── cli-orchestrator/scope.json
│   ├── refresh-pipeline/scope.json
│   ├── source-system/scope.json
│   ├── storage/scope.json
│   ├── summarizer/scope.json
│   ├── telegram-client/scope.json
│   └── tui/scope.json
└── runs/                    ← exploration + synthesis output (regenerated)
    ├── <slug>/
    │   ├── cartographer/exploration/
    │   │   ├── scope.json
    │   │   ├── queue_all.txt / queue_explored.txt
    │   │   ├── waves.json             ← v2: wave plan
    │   │   ├── cgc_graph.json         ← v2: AST dependency data
    │   │   ├── revision.json          ← v2: SHA tracking
    │   │   ├── findings.md            ← synthesis output
    │   │   ├── scope-manifest.json    ← v2: machine-readable manifest
    │   │   ├── nodes/*.json           ← v2 nodes (contracts, observations)
    │   │   └── edges/*.json           ← v2 edges (semantic, data_flow)
    │   ├── explore.log
    │   ├── synthesis.log
    │   ├── internal/ → symlink to tg-digest/internal/
    │   └── cmd/ → symlink to tg-digest/cmd/
    └── architecture.md        ← v2: cross-scope synthesis

```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EXPLORE_MODEL` | sonnet | Exploration model |
| `SYNTH_MODEL` | sonnet | Per-scope synthesis model |
| `CROSS_MODEL` | opus | Cross-scope synthesis model |
| `PROVIDER` | claude | AI CLI provider (claude, cursor) |
| `SOURCE_ROOT` | (auto) | Git repo for incremental SHA tracking |

## Results

### v2 (2026-03-21, Sonnet exploration + synthesis, Opus cross-scope)

**Exploration**: 7 scopes, 7 parallel Sonnet wave explorers

```
SCOPE                  FILES  NODES  EDGES
cli-orchestrator           4      4      4
refresh-pipeline           3      3      3
source-system             11     11     11
storage                   11     11     11
summarizer                 9      9      9
telegram-client            4      4      4
tui                       15     15     15
TOTAL                     57     57     57
```

100% file coverage. All v2 nodes include role, contracts, effects, state,
typed observations with loc references.

**Per-scope Synthesis** (Sonnet): 7/7 findings.md + 7/7 scope-manifest.json

```
cli-orchestrator           166 lines
refresh-pipeline           124 lines
source-system              145 lines
storage                    171 lines
summarizer                 137 lines
telegram-client            146 lines
tui                        179 lines
```

**Cross-scope Synthesis** (Opus): 290-line architecture.md with:
- System dependency map
- Data lineage tracing 4 entities across scope boundaries
- 8 cross-scope findings (broken RefreshFiltered, silent error chain, no HTTP timeouts, etc.)
- Systemic patterns analysis (error handling, config, HTTP, testing, DI)
- Architectural assessment with structural debt

**Incremental**: Tested — changed 1 file, only that file re-explored (not all 11).

### v1 Baseline (2026-03-16, Haiku exploration, Opus synthesis)

57/57 files, 59 nodes, 1086 lines of findings. Opus review scores:
Accuracy 9.0, Completeness 8.3, Usefulness 9.0.

### v1 → v2 Comparison

| Aspect | v1 | v2 |
|--------|-----|-----|
| Exploration model | Haiku (batch of 3) | Sonnet (wave-based) |
| Node schema | flat (summary, notes) | rich (contracts, effects, observations) |
| Edge schema | bare (relationship, usage) | semantic (data_flow, coupling type) |
| Synthesis model | Opus | Sonnet |
| New: scope-manifest.json | — | per scope |
| New: architecture.md | — | cross-scope Opus analysis |
| New: incremental | — | SHA-tracked, per-file |
| Opus calls | 7 (synthesis) | 2 (prephase + cross-scope) |

## Issues Found During Testing

### v2-specific

1. **CGC `| head -5` SIGPIPE** — `set -e` caught broken pipe from early pipe close. Fixed with `|| true`.
2. **scope-manifest.json not written by agent** — Sonnet with `--output-format text` didn't use Write tool. Fixed by generating manifest programmatically from node/edge data.
3. **architecture.md wrapped in code fences** — Prompt said "write to file" but agent only had Read. Fixed prompt to "output as text."
4. **Wrong git SHA in revision.json** — `git -C "$PROJECT_ROOT"` resolved through symlinks to cartographer repo. Fixed by adding `SOURCE_ROOT` env var.

### v1 (see hallucination-bug.md for details)

1. claude -p path resolution — agents wrote to global dir instead of isolated
2. ignore field — queued files were skipped, burning iterations
3. Budget limits — guaranteed incomplete exploration
4. CGC path prefix — requires manual sed stripping
5. Tool permissions for synthesis — needed explicit `--tools "Read"`
6. Haiku/Sonnet synthesis quality — hallucinated signatures (accuracy 6.9/10)
