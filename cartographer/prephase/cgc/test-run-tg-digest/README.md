# CGC Pre-Phase Test Run: tg-digest

End-to-end test of the full cartographer pipeline — CGC prephase → parallel
exploration → source-verified synthesis — against the tg-digest Go application
(53 files, 7 internal packages + cmd).

## Target

`/home/dev/project/tg-digest` — Telegram channel digest app. Go codebase with
packages: storage, config, telegram, source (4 implementations), refresh,
summarizer, tui (Bubble Tea), and cmd/digest entrypoint.

## Prerequisites

```bash
pip install codegraphcontext kuzu
```

CGC must have the repo indexed:

```bash
cgc index /home/dev/project/tg-digest
cgc list   # should show tg-digest
```

## How to Run

### Step 1: Pre-phase (produces scopes)

```bash
./cartographer/prephase/cgc/test-run-tg-digest/run.sh
```

This runs `cgc/AUTO_PROMPT.md` with MCP access to the CGC graph. The agent
queries the dependency graph, identifies slices, and writes:
- `slices.json` — all slices with metadata
- `scopes/<slug>/scope.json` — one scope file per slice

The prephase runs on the default model (Opus). It needs MCP tool access to
query the graph interactively.

### Step 2: Fix CGC path prefix (manual, if needed)

CGC indexes paths with the repo name as prefix (`tg-digest/internal/...`).
The parallel runner symlinks source dirs without this prefix. If the prephase
produced prefixed paths, strip them:

```bash
for f in scopes/*/scope.json; do
    sed -i 's|tg-digest/||g' "$f"
done
```

### Step 3: Parallel exploration (produces nodes/edges)

```bash
./cartographer/prephase/cgc/test-run-tg-digest/run-all.sh
```

This creates isolated directory trees per scope, runs `--init` for each,
then launches all cartographers in parallel. Default model: Haiku.

Override model: `EXPLORE_MODEL=sonnet ./run-all.sh`

### Step 4: Parallel synthesis (produces findings.md per scope)

```bash
./cartographer/prephase/cgc/test-run-tg-digest/synthesize-all.sh
```

Consolidates nodes/edges per scope, feeds them plus `SYNTHESIS_PROMPT.md`
to an Opus agent that also has Read access to the actual source files.
The agent uses structured exploration data as a map, then reads source
code to verify signatures, trace real call chains, and confirm behavioral
claims. Output is `findings.md` per scope.

Default model: Opus. Override: `SYNTH_MODEL=sonnet ./synthesize-all.sh`
Source root: `SOURCE_ROOT=/path/to/repo ./synthesize-all.sh`

Key flags passed to `claude -p`:
- `--tools "Read"` — only the Read tool is available (no Write/Bash/Edit)
- `--add-dir "$SOURCE_ROOT"` — grants read access to the source tree
- `--allowedTools "Read"` — auto-approves Read (no permission prompts)

## File Structure

```
test-run-tg-digest/
├── README.md              ← this file
├── run.sh                 ← prephase runner (CGC auto mode)
├── run-all.sh             ← parallel cartographer launcher
├── synthesize-all.sh      ← parallel synthesis launcher
├── hallucination-bug.md   ← writeup of claude -p path resolution issue
├── auto.log               ← prephase session log
├── slices.json            ← prephase output (all slices, extraction_mode: cgc)
├── scopes/                ← one scope.json per slice (durable)
│   ├── cli-orchestrator/scope.json
│   ├── refresh-pipeline/scope.json
│   ├── source-system/scope.json
│   ├── storage/scope.json
│   ├── summarizer/scope.json
│   ├── telegram-client/scope.json
│   └── tui/scope.json
└── runs/                  ← exploration + synthesis output (regenerated)
    ├── <slug>/
    │   ├── cartographer/
    │   │   ├── explore.sh
    │   │   ├── PROMPT.md        ← generated with absolute paths (sed)
    │   │   ├── exploration/
    │   │   │   ├── scope.json
    │   │   │   ├── queue_all.txt
    │   │   │   ├── queue_explored.txt
    │   │   │   ├── index.json
    │   │   │   ├── findings.md  ← synthesis output
    │   │   │   ├── nodes/*.json
    │   │   │   └── edges/*.json
    │   │   └── logs/
    │   ├── synthesis.log        ← synthesis stderr
    │   ├── review.md            ← Opus review of findings accuracy
    │   ├── internal/ → symlink to tg-digest/internal/
    │   ├── cmd/      → symlink to tg-digest/cmd/
    │   └── explore.log
    └── ...
```

## How Parallel Isolation Works

`claude -p` resolves file paths from the git project root, not from the
shell's working directory. This means all agents would write to the same
global `cartographer/exploration/` if given relative paths.

The fix: `run-all.sh` generates a per-scope `PROMPT.md` with absolute paths
by sed-replacing `cartographer/exploration/` with the full path to that
scope's exploration directory. Source files are symlinked so the agent can
read them at the expected relative paths.

## Results (2026-03-16)

### Exploration

7 slices, 7 parallel Haiku cartographers, no budget limits:

```
cli-orchestrator        4/4  explored    6 nodes   6 edges
refresh-pipeline        3/3  explored    3 nodes   3 edges
source-system          11/11 explored   11 nodes  11 edges
storage                11/11 explored   11 nodes  11 edges
summarizer              9/9  explored    9 nodes   9 edges
telegram-client         4/4  explored    4 nodes   4 edges
tui                    15/15 explored   15 nodes  15 edges
────────────────────────────────────────────────────────
TOTAL                  57/57 explored   59 nodes  59 edges
```

100% file coverage. Every queued file explored.

### Synthesis (Opus, source-verified)

```
cli-orchestrator           157 lines
refresh-pipeline           150 lines
source-system              147 lines
storage                    183 lines
summarizer                 157 lines
telegram-client            121 lines
tui                        171 lines
```

### Quality Review (Opus reviewers, verified against source)

Each findings.md was reviewed by an Opus agent that read both the doc and
all referenced source files, then scored accuracy, completeness, and
usefulness.

| Scope            | Accuracy | Completeness | Usefulness |
|------------------|----------|--------------|------------|
| source-system    | 9/10     | 9/10         | 9/10       |
| storage          | 9/10     | 8/10         | 9/10       |
| cli-orchestrator | 9/10     | 8/10         | 9/10       |
| refresh-pipeline | 9/10     | 8/10         | 9/10       |
| telegram-client  | 9/10     | 8/10         | 9/10       |
| summarizer       | 9/10     | 9/10         | 9/10       |
| tui              | 9/10     | 8/10         | 9/10       |
| **Average**      | **9.0**  | **8.3**      | **9.0**    |

Zero hallucinated signatures or fabricated behaviors. Remaining completeness
gaps are cross-boundary details requiring code outside the explored scope.

#### Comparison: without source access (Haiku/Sonnet synthesis)

An earlier run used Haiku/Sonnet without source code access. Average scores:
Accuracy 6.9, Completeness 7.1, Usefulness 7.9. The accuracy jump (6.9 → 9.0)
came from two changes: Opus model + Read access to source files for
fact-checking during synthesis.

## Issues Found During Testing

### 1. claude -p path resolution (fixed)

Agents wrote to global `cartographer/exploration/` instead of isolated dirs.
Cross-contamination between parallel runs. Fixed with absolute paths in
PROMPT.md. See `hallucination-bug.md`.

### 2. ignore field (removed)

`ignore: ["**/*_test.go", "**/*.md"]` caused two problems:
- explore.sh queued test files but the agent skipped them, leaving them
  permanently stuck in the queue and burning iterations
- Prephase undercounted files (excluded tests from analysis), producing
  wrong budget sizes

Fix: removed `ignore` from the scope.json schema entirely. `explore_within`
+ `boundary_packages` is sufficient.

### 3. Budget limits (removed)

The budget table (max_nodes, max_iterations, max_depth_from_seed) was
vestigial from an older design where the agent discovered files dynamically.
With `--init` pre-queuing all files, the natural stop condition is "queue
empty." Budget caps guaranteed incomplete exploration:
- With budget: 50/57 explored (88%)
- Without budget: 57/57 explored (100%)

Fix: removed budget from scope.json schema and all prompts. explore.sh now
computes a safety iteration limit as `ceil(queued / BATCH_SIZE) * 2`.

### 4. CGC path prefix (manual workaround)

CGC graphs use the repo directory name as a path prefix
(`tg-digest/internal/...`). The symlinked directory structure doesn't have
this level. Requires manual `sed` stripping after prephase. Future fix: teach
the prephase prompt to emit paths relative to the repo root, not including
the repo name.

### 5. claude -p tool permissions for synthesis (fixed)

Opus synthesis agents attempted to use Read tool but were blocked by
permission prompts in non-interactive mode. Also tried to Write the output
file instead of outputting to stdout. Fixed with:
- `--tools "Read"` — restricts available tools to Read only
- `--allowedTools "Read"` — auto-approves Read without prompts
- `--add-dir "$SOURCE_ROOT"` — grants access to source tree
- Explicit prompt instruction: "Output markdown as your response text,
  do not use write tools"

### 6. Haiku/Sonnet synthesis quality (resolved by using Opus)

Haiku produced meta-commentary ("Approve the write and I'll save it")
instead of actual findings for 3/7 scopes. Sonnet worked but wrapped
output in code blocks. Both hallucinated function signatures at high rates
(accuracy 6-7/10). Resolved by using Opus for synthesis — accuracy jumped
to 9/10 across all scopes.
