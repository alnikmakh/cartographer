# Cartographer v2 — Concept

## Core Idea

Split the pipeline by what each tool is best at:

- **AST (cgc)** → structure (perfect, instant, free): imports, exports, symbols, dependency graph
- **Sonnet** → judgment (per-file insights): architectural role, behavioral observations, contracts, risks
- **Opus** → adversarial review (cross-cutting): find what Sonnet missed, contradictions, systemic patterns

## Pipeline

```
1. cgc index <package>              → AST graph (imports, exports, symbols, edges)
2. Strip files to signatures        → lightweight skeleton per file
3. Sonnet exploration (parallel)    → insight nodes + semantic edges
4. Opus synthesis (adversarial)     → cross-cutting findings, challenges exploration output
```

### Sonnet Exploration

Sonnet receives:
- The full AST dependency graph
- Stripped file (signatures, types, declarations — no bodies)
- Read access to full source files

Prompt: "Here's the skeleton. The graph tells you who depends on whom.
Identify what's architecturally notable. If you need to see the
implementation of a function to confirm a suspicion, read the full file."

Sonnet self-regulates depth: skims ~70% of files from skeleton alone,
deep-reads ~30% where signatures hint at something worth investigating.

### Opus Synthesis (Adversarial)

Opus's job is NOT to compile Sonnet's notes into prose. It's to
**challenge, cross-reference, and find what the explorer missed.**

What Opus catches that Sonnet can't:

- **Cross-scope blind spots** — 6 scopes each implement retry logic differently
- **Implicit coupling** — scope A writes to table X, scope B reads from it
- **Contradictions** — scope A says "single auth entry point", scope B checks JWT directly
- **Systemic patterns** — are error handling strategies consistent across the codebase?
- **Architectural violations** — dependency cycles, layering violations, god modules

Output: cross-cutting architectural review across all scopes, plus per-scope
addenda for anything Opus found that Sonnet missed.

## Incremental Regeneration

### Revision tracking

Save `git rev-parse HEAD` to `exploration/revision.txt` after generation.

### Incremental update flow

```
1. cgc index (instant)              → fresh AST graph, always
2. git diff --name-only <saved-sha> HEAD → changed files
3. Sonnet explores only changed files (stripped + selective deep read)
4. Keep existing Sonnet nodes for unchanged files
5. Opus review: "these files changed — here's the diff, updated nodes.
   Do the existing findings still hold?"
```

Cost: Sonnet on ~5 files + Opus on the diff ≈ $1-2 instead of $15-20 full regen.

## Node Format

Nodes carry only what LLM provides — AST handles imports, exports, symbols.

```json
{
  "path": "src/auth/service.ts",
  "role": "orchestrator",
  "summary": "Coordinates JWT validation, session lifecycle, and RBAC checks for every authenticated request",

  "contracts": {
    "requires": ["JWT_SECRET env var", "Redis reachable"],
    "guarantees": ["Returns complete AuthContext or throws AuthError — never partial state"]
  },

  "effects": [
    "Redis read/write on every authenticated request (session lookup/create)",
    "Logs auth failures to stdout with user IP"
  ],

  "state": "LRU cache of decoded JWT claims, 5-min TTL, not shared across instances",

  "observations": [
    {
      "kind": "behavior",
      "text": "System-to-system calls (x-service-auth header) bypass permission checks entirely",
      "loc": "service.ts:142-155"
    },
    {
      "kind": "risk",
      "text": "Revoked tokens stay valid up to 5 min — cache has no invalidation hook"
    },
    {
      "kind": "pattern",
      "text": "Fail-fast: validates JWT_SECRET at construction, not first request"
    }
  ]
}
```

### Field reference

| Field | Why Opus needs it | Required |
|-------|------------------|----------|
| `path` | File identification | Always |
| `role` | Instant triage — skip utilities, focus on orchestrators | Always |
| `summary` | Dense orientation — WHAT + WHY | Always |
| `contracts` | Trace assumption mismatches across boundaries | When non-trivial |
| `effects` | Map external system dependencies without reading source | When present |
| `state` | Critical for data flow, concurrency, caching analysis | When stateful |
| `observations` | **The entire point.** Things invisible from signatures | When notable |

### Role taxonomy (not an enum — Sonnet chooses the best fit)

General: `entry-point`, `orchestrator`, `adapter`, `model`, `utility`, `config`, `middleware`, `factory`, `test`
Frontend: `container`, `presenter`, `hook`, `context`, `layout`
Backend: `handler`, `repository`, `migration`, `worker`

### Observation kinds

- **`behavior`** — how it actually works, especially when surprising. Include `loc`.
- **`risk`** — something that could break, drift, or cause incidents
- **`pattern`** — design pattern or convention in use (or violated)
- **`coupling`** — non-obvious dependency on another file, config, or external system
- **`invariant`** — assumption the code makes that isn't enforced by types

### Graceful degradation

Boring files get minimal nodes:

```json
{
  "path": "src/utils/format-date.ts",
  "role": "utility",
  "summary": "Date formatting for display layer, wraps Intl.DateTimeFormat",
  "observations": [
    {
      "kind": "behavior",
      "text": "Output varies by runtime locale — no explicit locale pinning"
    }
  ]
}
```

## Edge Format

AST provides structural edges (file A imports file B). Sonnet annotates
with semantic meaning — what the relationship actually does.

```json
{
  "from": "src/auth/service.ts",
  "to": "src/auth/jwt.ts",
  "semantic": "delegates token parsing and signature verification",
  "data_flow": "raw JWT string → decoded Claims",
  "coupling": "direct"
}
```

### Coupling values

- `direct` — concrete function calls, tight binding
- `interface-mediated` — depends on abstraction, swappable
- `event-driven` — pub/sub, observer, callbacks
- `config-mediated` — shared config or env vars create implicit coupling

### Data flow notation

- `→` for one-way flow (A sends to B)
- `↔` for bidirectional (A and B exchange)
- Name the actual types/shapes that cross the edge

### Boundary edges

External systems use `[brackets]`:

```json
{
  "from": "src/auth/service.ts",
  "to": "[Redis]",
  "semantic": "session storage backend",
  "data_flow": "session ID → serialized Session",
  "coupling": "interface-mediated via SessionStore"
}
```

## Parallelization

Exploration is embarrassingly parallel — each file is independent.

- AST graph is pre-computed, read-only during exploration
- Nodes/edges are per-file, unique filenames, no write conflicts
- No shared mutable state (index.json built post-hoc from nodes)
- `PARALLEL` env var controls concurrency (default 4-5)

Post-hoc collection after all parallel agents finish:
- Build `index.json` by scanning `nodes/*.json`
- Build `queue_explored.txt` from existing node files
- Merge boundary nodes that multiple agents touched

## Cost Model

| Phase | Model | Scales with | Approximate cost (300 files) |
|-------|-------|------------|------------------------------|
| AST graph | cgc | File count | Free, instant |
| Exploration | Sonnet | Files × depth | $10-20 (full), $1-3 (incremental) |
| Synthesis | Opus | Scope count × scope size | $5-15 |

Full generation: ~$15-35 for 300 files across ~10 scopes.
Incremental (5 files changed): ~$2-5.
