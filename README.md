# Scout — Autonomous Codebase Explorer

Scout is a queue-driven loop that uses AI agents to map how a codebase works. You give it entry points and boundaries, and it traces every connection — function calls, DI, events, config pipelines — building a self-contained explanation map.

It does **not** fix or change anything. It only reads and documents.

## How It Works

```
                    ┌──────────────────────┐
                    │   run-scout.sh       │
                    │   checks QUEUE.md    │
                    └─────────┬────────────┘
                              │
               ┌──────────────┴──────────────┐
               │                             │
        unchecked edges?               no unchecked?
               │                             │
               ▼                             ▼
      ┌─────────────────┐          ┌─────────────────┐
      │  PROVING mode   │          │ DISCOVERY mode   │
      │  Confirm 1 edge │          │ Find 5-10 edges  │
      │  Read 2 files   │          │ Read 3-5 files   │
      └────────┬────────┘          └────────┬─────────┘
               │                             │
               └──────────────┬──────────────┘
                              │
                        <promise>DONE
                              │
                         next iteration
```

Two modes alternate automatically:

- **Discovery** — Broad, shallow. Reads frontier files, identifies connections, adds them as unchecked edges to the queue.
- **Proving** — Deep, precise. Picks one unchecked edge, reads the source and target files, confirms the connection, writes a data-flow summary.

The loop ends when discovery finds no remaining frontier (`ALL_DONE`).

## Prerequisites

One of these CLI tools installed and on your PATH:

| Provider | CLI | Install |
|----------|-----|---------|
| Claude Code | `claude` | `npm i -g @anthropic-ai/claude-code` |
| OpenAI Codex | `codex` | `npm i -g @openai/codex` |
| Google Gemini | `gemini` | `npm i -g @anthropic-ai/claude-code` / Gemini CLI |
| GitHub Copilot | `copilot` | VS Code extension CLI |

## Setup

### 1. Write `scout/CONTEXT.md`

This is the only file you need to edit. Define:

```markdown
# Scout Context

## Entry Points

- path/to/file.ts:42 — functionName() description of why this is an entry point

## Boundaries

Explore within:
- packages/billing
- packages/shared (only modules imported by billing)

Do NOT explore:
- packages/frontend
- node_modules

## Max Depth

15 hops from any entry point.

## Notes

- Any important context the agent should know (DI frameworks, event patterns, etc.)
```

### 2. Clear the queue and overview

Reset `scout/QUEUE.md` to the empty template:

```markdown
# Edge Queue

## Relevant Edges

FORMAT: - [ ] [dN] source_file:line function → target_file:line function — edge_type
PROVEN: - [x] [dN] (same) — SUMMARY: what goes in, what happens, what comes out

edge_type: call | DI | event | config | middleware | re-export


## Irrelevant Edges (noted, not explored)

FORMAT: - source_file:line function → target — SKIPPED: reason
```

Reset `scout/OVERVIEW.md` to the empty template:

```markdown
# Explanation Map

## Entry Points

(filled by agent from CONTEXT.md on first iteration)

## Call Chain

(agent appends proven edges here as they are confirmed)

## Key Types

(agent appends type definitions encountered during proving)

## Data Flow

(agent appends data transformation descriptions here)

## Noted but Not Explored

(agent copies irrelevant edges here with explanations from QUEUE.md)
```

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

## Output

When finished, `scout/OVERVIEW.md` contains the complete explanation map with:

- **Call Chain** — every proven connection with file:line references
- **Key Types** — type definitions encountered along the way
- **Data Flow** — what data goes in, how it transforms, what comes out
- **Noted but Not Explored** — connections that exist but were outside scope

The map is self-contained. A reader should understand the full structure without opening any source files.

## Logs

All output is captured in `logs/`:

- `logs/scout_session_*.log` — full session transcript
- `logs/scout_discover_iter_*.log` — per-iteration discovery output
- `logs/scout_prove_iter_*.log` — per-iteration proving output

## Safety

- The agent **never modifies source code**. It only reads source files and writes to `scout/QUEUE.md` and `scout/OVERVIEW.md`.
- File budget per iteration: 5 files (discovery), 2 files (proving).
- Consecutive failure limit: 3 iterations without a completion signal stops the loop.
- All agents run with `--dangerously-skip-permissions` (or equivalent). Review the output.

## File Structure

```
.
├── run-scout.sh                  # Main loop script
├── scout/
│   ├── CONTEXT.md                # YOU EDIT THIS — entry points, boundaries, depth
│   ├── QUEUE.md                  # Edge queue (managed by the agent)
│   ├── OVERVIEW.md               # Output explanation map (built by the agent)
│   ├── PROMPT_discover.md        # Discovery mode prompt (sent to agent)
│   └── PROMPT_prove.md           # Proving mode prompt (sent to agent)
├── specs/
│   └── 001-build-overview/       # Spec defining the scout workflow
├── .specify/memory/
│   └── constitution.md           # Agent behavioral rules
├── logs/                         # All output logs
└── ralph-wiggum/                 # Upstream Ralph Wiggum framework
```

## Customization

- **Edge types**: Edit `scout/PROMPT_discover.md` to add or remove edge type categories.
- **File budgets**: Edit `.specify/memory/constitution.md` to change per-iteration limits.
- **Max depth**: Set in `scout/CONTEXT.md` per exploration run.
- **Provider CLI path**: Set `CLAUDE_CMD`, `CODEX_CMD`, or `GEMINI_CMD` environment variables to override default binary names.

## Credits

Built on [Ralph Wiggum](https://github.com/fstandhartinger/ralph-wiggum) — autonomous AI coding with spec-driven development by Geoffrey Huntley's methodology.
