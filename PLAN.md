# Cartographer v2 — Implementation Plan

## Context

Cartographer v1 is a working pipeline: CGC prephase (Opus scoping) → Haiku file-by-file exploration → Opus per-scope synthesis → findings.md. It scores 9.0/10 accuracy on tg-digest (57 files, 7 scopes).

v2 restructures the pipeline to separate concerns by what each tool is best at: AST for structure, Sonnet for per-file judgment, Opus for cross-cutting review. The key changes:

1. **AST-first**: CGC provides the structural graph (imports, exports, symbols, edges) upfront — LLMs no longer discover structure
2. **Sonnet wave exploration**: Replaces Haiku batch exploration with Sonnet reading full source in intelligently-ordered waves
3. **Richer node/edge schema**: Contracts, effects, state, typed observations replace flat summaries
4. **Two-tier Opus synthesis**: Per-scope synthesis produces findings.md + scope-manifest.json; cross-scope synthesis produces architecture.md
5. **Incremental regeneration**: Per-scope revision tracking, three levels of incremental update

## Pipeline Overview

```
CGC index (instant, free)
  → Opus prephase: purpose-first scopes (existing, mostly unchanged)
  → Sonnet wave planning: groups scope files into ordered waves using CGC graph (new)
  → Sonnet wave exploration per scope: reads full source, accumulating context (new)
  → Sonnet per-scope synthesis → findings.md + scope-manifest.json (evolved)
  → Opus cross-scope synthesis → architecture.md (new)
```

**Model allocation**: Opus for decisions that require cross-cutting judgment (prephase scoping, cross-scope review). Sonnet for everything else (wave planning, exploration, per-scope synthesis). This keeps Opus cost to 2 calls (prephase + cross-scope) regardless of scope count.

## Implementation Steps

### Step 1: Wave Planning Prompt

**New file: `cartographer/WAVE_PLAN_PROMPT.md`**

Sonnet receives the CGC dependency graph for a scope and plans exploration waves. One cheap Sonnet call per scope — no file reading, just graph analysis.

Input (injected by script):
- scope.json (seed, explore_within, boundary_packages, hints)
- CGC graph data for scope: files, imports/exports, fan-in/fan-out counts, call relationships
  - Obtained via `cgc analyze deps`, `cgc analyze callers`, `cgc find` or Cypher queries
- Full file list for scope

Output: `waves.json` — ordered list of waves with rationale

```json
{
  "waves": [
    {
      "id": 1,
      "files": ["internal/storage/storage.go", "internal/storage/types.go"],
      "rationale": "Core types and store interface — foundation everything else depends on"
    },
    {
      "id": 2,
      "files": ["internal/storage/channels.go", "internal/storage/messages.go", "internal/storage/syncstate.go"],
      "rationale": "Repository implementations — tightly coupled, all implement interfaces from wave 1"
    }
  ]
}
```

Prompt guidance:
- Group tightly coupled files together (files that import each other, or that jointly implement an interface)
- Put foundational files first (types, interfaces, shared constants)
- Put consumers after their dependencies
- Group test files with their subjects when practical
- No hard cap on wave size — use judgment. Small focused waves for complex code, larger waves for simple utilities

### Step 2: Wave Exploration Prompt

**New file: `cartographer/EXPLORE_PROMPT.md`** (replaces PROMPT.md for v2)

Sonnet receives per wave:
- CGC dependency graph for entire scope — read-only structural context
- Nodes from previous waves — accumulating understanding
- The wave's file list + rationale from waves.json
- Read access to full source files (via Read tool)
- scope.json hints

Prompt structure:
```
## Context
- CGC graph: [imports, exports, dependency edges for entire scope]
- Prior wave output: [nodes from waves 1..N-1]
- Wave rationale: [why these files are grouped together]

## Your Task
Explore these files: [wave N file list]

Read each file's full source. Produce a v2 node (role, summary,
contracts, effects, state, observations) and semantic edges
(coupling type, data flow) for each file.

You have the full dependency graph for orientation and all prior
wave nodes for accumulated context. Focus on what's architecturally
notable — contracts, non-obvious behaviors, risks, coupling.
```

Key difference from v1: Sonnet has global structural context (CGC graph) + accumulated semantic context (prior nodes) but only reads source for its assigned wave files.

### Step 3: Wave Exploration Script

**Modified file: `cartographer/explore.sh`** → major rewrite

New behavior:
1. `--init`: validates scope.json, queries CGC graph data for scope, discovers all in-scope files
2. **Wave planning phase**: runs Sonnet with WAVE_PLAN_PROMPT.md + CGC graph → produces `waves.json`
3. **Wave execution loop**: iterates through waves.json sequentially
   - Each iteration: build prompt with CGC graph + prior nodes + wave files → run Sonnet explorer
   - After each wave: collect new nodes/edges, append to accumulator
4. Loop ends when all waves are explored

No script-level BFS, no caps, no graph partitioning logic — Sonnet owns the grouping decisions via waves.json. The script just executes the plan.

```bash
# Simplified loop
wave_plan=$(cat waves.json)
num_waves=$(echo "$wave_plan" | jq '.waves | length')

for i in $(seq 0 $((num_waves - 1))); do
    wave_files=$(echo "$wave_plan" | jq -r ".waves[$i].files[]")
    wave_rationale=$(echo "$wave_plan" | jq -r ".waves[$i].rationale")
    prior_nodes=$(consolidate_nodes)  # all nodes from waves 0..i-1

    run_sonnet_explorer "$wave_files" "$wave_rationale" "$prior_nodes" "$cgc_graph"

    # Check for new node files, mark explored
done
```

Model: `CLAUDE_MODEL=sonnet` by default (was haiku).

**CGC graph extraction** (run once during --init, reused across waves):
- `cgc analyze deps` — module-level dependencies
- `cgc query` with Cypher — file-level import/export edges, fan-in/fan-out counts
- Output stored as `exploration/cgc_graph.json` for injection into prompts

### Step 4: v2 Node/Edge Schema

**Node schema** (written by Sonnet during exploration):

```json
{
  "path": "src/auth/service.ts",
  "role": "orchestrator",
  "summary": "Coordinates JWT validation, session lifecycle, and RBAC checks",
  "contracts": {
    "requires": ["JWT_SECRET env var", "Redis reachable"],
    "guarantees": ["Returns AuthContext or throws AuthError — never partial"]
  },
  "effects": ["Redis read/write per authenticated request"],
  "state": "LRU cache of JWT claims, 5-min TTL, not shared across instances",
  "observations": [
    {
      "kind": "behavior",
      "text": "System-to-system calls bypass permission checks",
      "loc": "service.ts:142-155"
    },
    {
      "kind": "risk",
      "text": "Revoked tokens stay valid up to 5 min — no cache invalidation"
    }
  ]
}
```

Fields: path (always), role (always), summary (always), contracts (when non-trivial), effects (when present), state (when stateful), observations (when notable).

Role taxonomy: entry-point, orchestrator, adapter, model, utility, config, middleware, factory, test, container, presenter, hook, context, layout, handler, repository, migration, worker.

Observation kinds: behavior, risk, pattern, coupling, invariant.

**Edge schema** (written by Sonnet):

```json
{
  "from": "src/auth/service.ts",
  "to": "src/auth/jwt.ts",
  "semantic": "delegates token parsing and signature verification",
  "data_flow": "raw JWT string → decoded Claims",
  "coupling": "direct"
}
```

Coupling values: direct, interface-mediated, event-driven, config-mediated.
Boundary edges use `[brackets]` for external systems: `"to": "[Redis]"`.

### Step 5: Per-Scope Synthesis (Sonnet)

**Modified file: `cartographer/SYNTHESIS_PROMPT.md`** → evolved for v2

v1 required Opus for synthesis because Haiku exploration produced weak nodes — Opus had to compensate by reading source and doing the real analysis. In v2, Sonnet exploration produces rich nodes (contracts, typed observations, semantic edges), so per-scope synthesis is largely assembly and cross-referencing of high-quality structured data. Sonnet is sufficient here. Opus is reserved for cross-scope synthesis where adversarial cross-cutting analysis justifies the cost.

Changes from v1:
- **Model**: Sonnet (was Opus) — `SYNTH_MODEL=sonnet` default
- Input now includes v2 nodes (with contracts, effects, observations) instead of v1 nodes (flat summaries)
- Input includes semantic edges (with coupling types, data flow) instead of bare import edges
- **New output**: scope-manifest.json in addition to findings.md
- Cross-scope touchpoints explicitly declared

**findings.md** — stays largely the same (Purpose, Architecture, Data Flow, Boundaries, Non-Obvious Behaviors, Test Coverage Shape). Already scores 9.0/10 — don't break what works. Minor enhancement: leverage the richer node data (observations with loc references, contracts for boundary analysis).

**New output: scope-manifest.json** — machine-readable, compact, for cross-scope Opus:

```json
{
  "scope": "storage",
  "purpose": "SQLite persistence layer for channels, messages, sync state",
  "exposes": {
    "types": ["Channel", "Message", "SyncState"],
    "interfaces": ["ChannelRepository", "MessageRepository"],
    "entry_points": ["Open() → *Store"]
  },
  "consumes": {
    "external": ["[SQLite]"],
    "config": ["DATABASE_PATH env var"]
  },
  "cross_scope_touchpoints": [
    {
      "scope": "telegram",
      "direction": "consumed_by",
      "surface": "Channel type, Message type",
      "coupling": "direct"
    }
  ],
  "invariants": ["All DB access goes through Store"],
  "risks": ["No migration system — schema changes require manual ALTER TABLE"],
  "patterns": ["Repository pattern per entity type"]
}
```

**Modified file: `cartographer/synthesize.sh`** → add scope-manifest.json output

Two-pass synthesis or single pass with dual output. Simplest: single Opus call, prompt asks for both findings.md (to stdout) and scope-manifest.json (via Write tool). Change tool access from Read-only to Read+Write, with Write restricted to scope-manifest.json path.

### Step 6: Cross-Scope Synthesis

**New file: `cartographer/CROSS_SCOPE_PROMPT.md`**

Opus receives:
- All scope-manifest.json files (~50 lines each, total manageable)
- All scope findings.md files (for deeper context when needed)
- Read access to source files
- The AST dependency graph (cross-scope edges)

Prompt:
```
You are reviewing a codebase that has been explored scope-by-scope.
Each scope has a manifest (machine-readable) and findings (human-readable).

Your job is NOT to compile these into a summary. Your job is to:
1. Find cross-scope inconsistencies, contradictions, blind spots
2. Trace key entities across scope boundaries
3. Identify systemic patterns (or violations thereof)
4. Assess architectural health at the system level

Produce architecture.md with these sections:
- System Map: how scopes relate (from touchpoints)
- Data Lineage: key entities traced across boundaries
- Cross-Scope Findings: inconsistencies, implicit coupling, contradictions
- Systemic Patterns: what conventions hold/break across scopes
- Architectural Assessment: health, risks, structural debt
```

**New file: `cartographer/cross-synthesize.sh`**

Collects all scope-manifest.json + findings.md files, builds the prompt, runs Opus. Output: `exploration/architecture.md`.

### Step 7: Incremental Regeneration

**New file: `cartographer/exploration/revision.json`** (per scope)

```json
{
  "last_explored": "abc123",
  "last_synthesized": "abc123",
  "files_at_generation": ["internal/storage/storage.go", "..."],
  "cross_scope_revision": "def456"
}
```

**Modified file: `cartographer/explore.sh`** → add `--incremental` mode

```bash
explore.sh --incremental   # only re-explore changed files
```

Logic:
1. Read revision.json → get last SHA
2. `git diff --name-only <saved-sha> HEAD` → changed files
3. Map changed files to scope (match against explore_within globs)
4. For affected scopes: re-run Sonnet waves on changed files only, with all existing nodes as context
5. Update revision.json

**Modified file: `cartographer/synthesize.sh`** → add `--incremental` mode

After re-synthesis, diff old and new scope-manifest.json:
- If cross_scope_touchpoints, exposes, or invariants changed → flag cross-scope as stale
- If only internal details changed → cross-scope still valid

### Step 8: Orchestrator Script

**New file: `cartographer/run.sh`** — full pipeline orchestrator

```bash
run.sh <source-root>                    # full generation
run.sh <source-root> --incremental      # incremental update
```

Full pipeline:
1. `cgc index <source-root>` (instant)
2. Run prephase (auto.sh) → slices.json + scope.json files
3. Extract CGC graph data per scope → `cgc_graph.json`
4. For each scope (parallel): Sonnet wave planning → waves.json
5. For each scope (parallel): Sonnet wave exploration → v2 nodes/edges
6. For each scope (parallel): Sonnet synthesis → findings.md + scope-manifest.json
7. Opus cross-scope synthesis → architecture.md
8. Save revision.json per scope

Incremental pipeline:
1. `cgc index` (instant)
2. Compute changed files per scope
3. Re-explore changed files (Sonnet waves, existing nodes as context)
4. Re-synthesize affected scopes
5. If manifests changed: re-run cross-scope synthesis
6. Update revision.json

## File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `cartographer/WAVE_PLAN_PROMPT.md` | NEW | Sonnet wave planning prompt (uses CGC graph) |
| `cartographer/EXPLORE_PROMPT.md` | NEW | v2 Sonnet wave exploration prompt |
| `cartographer/CROSS_SCOPE_PROMPT.md` | NEW | Cross-scope Opus synthesis prompt |
| `cartographer/cross-synthesize.sh` | NEW | Cross-scope synthesis runner |
| `cartographer/run.sh` | NEW | Full pipeline orchestrator |
| `cartographer/explore.sh` | MODIFY | Wave planning + wave execution loop, --incremental mode |
| `cartographer/SYNTHESIS_PROMPT.md` | MODIFY | v2 node schema input, dual output (findings + manifest) |
| `cartographer/synthesize.sh` | MODIFY | scope-manifest.json output, --incremental mode |
| `cartographer/PROMPT.md` | KEEP | Archived as v1 reference, replaced by EXPLORE_PROMPT.md |

## Verification

1. **Wave planning**: Run on storage scope (11 files), verify Sonnet produces sensible wave groupings from CGC graph
2. **Wave exploration**: Execute planned waves, verify v2 nodes with contracts/observations produced
3. **Per-scope synthesis**: Run on storage scope, verify findings.md quality maintained + scope-manifest.json produced
4. **Cross-scope synthesis**: Run on all 7 tg-digest scopes, verify architecture.md identifies real cross-scope relationships
5. **Incremental**: Make a small change in tg-digest, run --incremental, verify only affected scope re-explored
6. **Full pipeline**: `run.sh /path/to/tg-digest` end-to-end, compare quality against v1 baseline (9.0/10)

## Implementation Order

1. WAVE_PLAN_PROMPT.md (Step 1) — wave planning prompt, can test with CGC immediately
2. EXPLORE_PROMPT.md + node/edge schema (Steps 2, 4) — the core exploration prompt
3. explore.sh wave mode (Step 3) — wiring wave planning + execution
4. SYNTHESIS_PROMPT.md + scope-manifest.json (Step 5) — evolved synthesis
5. cross-synthesize.sh + CROSS_SCOPE_PROMPT.md (Step 6) — new capability
6. Incremental mode (Step 7) — can layer on after full pipeline works
7. Orchestrator run.sh (Step 8) — ties it all together
