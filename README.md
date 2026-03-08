# Scout — Autonomous Codebase Explorer

Scout is a layer-based loop that uses AI agents to trace execution flows through a codebase. You give it entry points and boundaries, and it follows the call graph function-by-function — only tracing outgoing connections from functions that are reachable from your entry points.

It does **not** fix or change anything. It only reads and documents.

## How It Works

```
layer=0, frontier=entry point functions from CONTEXT.md

LOOP:
  ├─ DISCOVER (agent): read files, trace ONLY listed functions → QUEUE.md
  ├─ PROVE (agent, repeats): classify all unchecked edges in QUEUE.md
  ├─ ADVANCE (bash):
  │    explored = source file:line from ALL edges
  │    targets  = target file:line function() from RELEVANT edges
  │    next     = targets whose file:line ∉ explored
  │    next empty? ──────────── DONE
  │    layer >= max_depth? ──── DONE
  │    else → write next to FRONTIER.md, layer++
  └─ GOTO LOOP
```

Three phases per layer, strict ownership:

- **Discovery** — Reads files but only traces from functions listed in FRONTIER.md. Other functions in the same file are ignored (off-path). Adds connections as unchecked `- [ ]` edges to QUEUE.md.
- **Proving** — Batches edges by source file, reads source + target (2 files max), classifies each as relevant `- [x]` or irrelevant (moved to Irrelevant Edges section). Repeats until all unchecked edges are drained.
- **Advance** — Bash only. Extracts target references from proven edges as the next frontier. Neither agent touches FRONTIER.md.

The loop ends when bash finds no new frontier files or hits max depth.

## Prerequisites

One of these CLI tools installed and on your PATH:

| Provider | CLI | Install |
|----------|-----|---------|
| Claude Code | `claude` | `npm i -g @anthropic-ai/claude-code` |
| OpenAI Codex | `codex` | `npm i -g @openai/codex` |
| Google Gemini | `gemini` | Gemini CLI |
| GitHub Copilot | `copilot` | VS Code extension CLI |

## Setup

### 1. Write `scout/CONTEXT.md`

This is the only file you need to edit. Define:

```markdown
# Scout Context

## Entry Points

- path/to/file.go:42 — FunctionName() description of why this is an entry point

## Boundaries

Explore within:
- path/to/package/

Do NOT explore:
- path/to/other/
- Any *_test.go files

## Max Depth

5 hops from any entry point.

## Notes

- Any important context the agent should know (DI frameworks, event patterns, etc.)
```

### 2. Reset state

Copy templates to working files:

```bash
cp scout/templates/QUEUE.md scout/QUEUE.md
cp scout/templates/FRONTIER.md scout/FRONTIER.md
```

Or use `run-scout-all.sh` which resets automatically per context.

### 3. Run

```bash
# Claude (default), unlimited iterations
./run-scout.sh

# Claude, max 40 iterations
./run-scout.sh 40

# Other providers
./run-scout.sh codex 40
./run-scout.sh gemini 40
./run-scout.sh copilot 40
```

Press `Ctrl+C` to stop at any time.

### Run all contexts

If you have multiple feature contexts in `scout/contexts/`:

```bash
./run-scout-all.sh 30           # 30 iterations per feature
./run-scout-all.sh codex 30     # with a different provider
```

Results are saved to `scout/results/{name}-QUEUE.md`. Existing results are skipped (delete to re-run).

## Output

`scout/QUEUE.md` is the final output. It contains:

- **Edges** — every proven connection with `[x]`, file:line references, and data-flow summaries
- **Irrelevant Edges** — connections that exist but were outside scope, with explanations

## Edge Format

The edge format is machine-parsed by bash. The exact characters matter.

```
UNCHECKED:  - [ ] [dN] source_file:line function() → target_file:line function() — edge_type
PROVEN:     - [x] [dN] source_file:line function() → target_file:line function() — edge_type — SUMMARY: ...
IRRELEVANT: - source_file:line function() → target — SKIPPED: reason
```

Critical formatting rules:

| Rule | Why |
|------|-----|
| `→` must be U+2192, not `->` | Bash `grep -oP '→\s+\K.+?(?=\s+—)'` extracts target references |
| `[x]` must be lowercase | `grep '^\- \[x\]'` is case-sensitive — `[X]` is invisible |
| `- [ ]` at column 0, no indent | `grep '^\- \[ \]'` anchors to line start |
| `[dN]` with digit, not `[depth0]` | `grep -oP '\[d\d+\]\s+\K\S+'` extracts source file:line for explored set |
| `—` (em-dash) before edge_type | Bash extracts target as everything between `→` and `—` — missing `—` breaks it |
| Delete `- [ ]` when moving to Irrelevant | `count_unchecked` must reach 0 or prove loop runs forever |

## Logs

All output is captured in `logs/`:

- `logs/scout_session_*.log` — full session transcript
- `logs/scout_discover_iter_*.log` — per-iteration discovery output
- `logs/scout_prove_iter_*.log` — per-iteration proving output

## Safety

- The agent **never modifies source code**. It only reads source files and writes to `scout/QUEUE.md`.
- File budget: discovery reads files for listed functions only (not whole files), proving reads 2 files max.
- Consecutive failure limit: 3 iterations without a `<promise>DONE</promise>` signal stops the loop.
- FRONTIER.md is only written by bash, never by agents.
- All agents run with `--dangerously-skip-permissions` (or equivalent). Review the output.

## File Structure

```
.
├── run-scout.sh                  # Main loop script (layer-based)
├── run-scout-all.sh              # Run loop for each context in scout/contexts/
├── scout/
│   ├── CONTEXT.md                # YOU EDIT THIS — entry points, boundaries, depth
│   ├── QUEUE.md                  # Edge queue (agents write edges here)
│   ├── FRONTIER.md               # Current frontier (bash-managed, agents read only)
│   ├── PROMPT_discover.md        # Discovery mode prompt
│   ├── PROMPT_prove.md           # Proving mode prompt
│   ├── contexts/                 # Multiple feature contexts for run-scout-all.sh
│   ├── results/                  # Saved results per context
│   └── templates/                # Empty QUEUE.md and FRONTIER.md templates
├── .specify/memory/
│   └── constitution.md           # Agent behavioral rules
└── logs/                         # All output logs
```

## Customization

- **Edge types**: Edit `scout/PROMPT_discover.md` to add or remove edge type categories.
- **File budgets**: Edit `.specify/memory/constitution.md` to change per-iteration limits.
- **Max depth**: Set in `scout/CONTEXT.md` per exploration run.
- **Provider CLI path**: Set `CLAUDE_CMD`, `CODEX_CMD`, or `GEMINI_CMD` environment variables to override default binary names.
- **Model override**: Set `CLAUDE_MODEL` or `GEMINI_MODEL` to use a specific model.
