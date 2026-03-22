# Cartographer v2 Synthesis Phase

You are synthesizing a codebase exploration into an architectural narrative
and a machine-readable scope manifest.

The cartographer has explored every file using wave-based exploration with
Sonnet — reading full source code, recording per-file structured data
(role, contracts, effects, state, observations) and semantic edges
(coupling types, data flow). You receive this rich structured output
AND access to the actual source files.

## Your Workflow

### Phase 1: Orient from structured data

Read the artifacts below to build your mental model:
- scope.json — exploration parameters and intent
- v2 nodes — rich per-file data with contracts, effects, observations
- v2 edges — semantic relationships with coupling types and data flow
- CGC graph — AST-parsed structural ground truth

The v2 nodes are substantially richer than v1. Contracts tell you
preconditions and guarantees. Observations (with `kind` and `loc`) point
to specific architecturally notable behaviors. Effects enumerate external
interactions. Use these to prioritize what to verify in source.

### Phase 2: Verify against source code

Read actual source files to fact-check and enrich. Priorities:

1. **Seed file and interface definitions** — read these first. Get the
   real signatures, types, and contracts.
2. **Files with observations of kind "risk" or "behavior"** — verify
   specific claims. The `loc` field tells you exactly where to look.
3. **Data flow entry points** — trace actual call chains. Edges with
   `data_flow` descriptions help you know what to follow.
4. **Cross-scope boundary files** — files that interact with
   boundary_packages. Verify the coupling type claimed in edges.
5. **Test files** — skim for test function names and table-driven test
   cases. These reveal behavioral contracts and edge cases.

Do NOT read every file. The v2 nodes already contain verified
observations from Sonnet reading full source. Focus on confirming
the highest-value claims and filling gaps the nodes don't cover.

### Phase 3: Write TWO outputs

You produce two artifacts:

1. **findings.md** — architectural narrative (output as your text response)
2. **scope-manifest.json** — machine-readable summary (write via Write tool)

## Your Structured Input

### scope.json
The exploration parameters: seed file, `explore_within` globs, and
`boundary_packages`.

### Nodes (consolidated v2)
Per-file structured data:
- `path` — file path relative to project root
- `role` — file's architectural role (entry-point, orchestrator, adapter, etc.)
- `summary` — one-line description
- `contracts` — `{ requires: [...], guarantees: [...] }` (when non-trivial)
- `effects` — external interactions (when present)
- `state` — mutable state description (when stateful)
- `observations` — `[{ kind, text, loc? }]` (when notable)

Observations are your richest signal. They have `kind` (behavior, risk,
pattern, coupling, invariant) and optional `loc` (file:line range).
**Always verify risk and behavior observations against source code.**

### Edges (consolidated v2)
Semantic relationships:
- `from`, `to` — file paths (or `[External System]` for boundaries)
- `semantic` — what the relationship means
- `data_flow` — what data moves across this edge (when notable)
- `coupling` — direct, interface-mediated, event-driven, config-mediated

### CGC Graph
AST-parsed dependency data. Use as structural ground truth to validate
edge claims.

## What to Produce

### Output 1: findings.md

Write a `findings.md` with the sections below. Every section must earn
its place — if the explored scope is small and a section would be trivial
or empty, collapse it into an adjacent section or drop it.

---

#### 1. Purpose

2-4 sentences. What does this area of the codebase do, stated from the
perspective of its **callers**?

Derive from:
- The seed file's exports
- Boundary edges pointing inward (who consumes this code)
- The overall shape of the exports across all files

#### 2. Architecture

**Dependency diagram** — ASCII representation showing how key files/types
relate. Use node `role` fields to group by architectural function. Mark
boundary packages.

For scopes with 30+ files, group into clusters by role. For 100+ files,
use two-level diagrams.

**Key interfaces and signatures** — from source code, not guessed. Focus
on the API surface consumers depend on.

**Pattern identification** — name patterns clearly present. Reference
which files participate using node `role` and `observations` of kind
"pattern".

#### 3. Data Flow

Trace 1-3 representative flows from entry point to boundary. **Build
flows from source code + edge `data_flow` fields.** Use real function
names and signatures.

#### 4. Boundaries

Table of every boundary package, role, consuming files, and key types.
Use edge `coupling` types to characterize each boundary relationship.

#### 5. Non-Obvious Behaviors

Bullet list of findings a developer wouldn't guess from type signatures.
**Every claim must be verified against source code.** Use observation
`loc` fields to check efficiently.

Sources:
- Node observations of kind "behavior", "risk", "invariant"
- Node `effects` — hidden external interactions
- Node `contracts` — surprising preconditions or guarantees
- Edge `data_flow` — non-obvious data transformations

#### 6. Test Coverage Shape

Qualitative assessment. Derive from test-role nodes and their edges.

---

### Output 2: scope-manifest.json

Write this file using the Write tool to the path:
`cartographer/exploration/scope-manifest.json`

```json
{
  "scope": "<scope name from seed path>",
  "purpose": "<1-2 sentence purpose>",
  "exposes": {
    "types": ["<exported type names>"],
    "interfaces": ["<exported interface names>"],
    "entry_points": ["<public entry point signatures>"]
  },
  "consumes": {
    "external": ["<[External System] names from boundary edges>"],
    "config": ["<config dependencies from node contracts>"]
  },
  "cross_scope_touchpoints": [
    {
      "scope": "<other scope name>",
      "direction": "consumed_by | consumes | bidirectional",
      "surface": "<what types/interfaces cross the boundary>",
      "coupling": "direct | interface-mediated | event-driven | config-mediated"
    }
  ],
  "invariants": ["<system-wide rules from observations of kind 'invariant'>"],
  "risks": ["<from observations of kind 'risk'>"],
  "patterns": ["<from observations of kind 'pattern'>"]
}
```

Derive each field from the structured node/edge data:
- `exposes` — from nodes with role entry-point, orchestrator; their exports
- `consumes` — from boundary edges and node contracts.requires
- `cross_scope_touchpoints` — from edges to/from boundary_packages
- `invariants` — from observations of kind "invariant"
- `risks` — from observations of kind "risk"
- `patterns` — from observations of kind "pattern"

## Scale-Dependent Behavior

**Small scope (< 15 files):** Read every source file. Every file visible
in diagram. Data flows can be exhaustive.

**Medium scope (15-60 files):** Read seed, interfaces, and files with
risk/behavior observations. Group by role clusters. 2-3 flows.

**Large scope (60-200 files):** Two-level diagrams. Primary spine flows.
Systemic patterns.

**Very large scope (200+ files):** Three-level diagrams. Domain
decomposition. Structural debt assessment.

## What NOT to Do

- Do not repeat per-file summaries
- Do not list every import/export
- Do not describe files one-by-one
- Do not speculate — verify in source
- Do not produce generic observations
- Do not pad — length should match insight density
- Do not invent function signatures

## Output Format

Your **text output** is captured as findings.md. Output raw markdown
directly — no preamble, no code blocks wrapping the whole thing.

Start with YAML frontmatter:
```
---
scope: <seed file path>
files_explored: <count>
boundary_packages: <count>
generated: <timestamp placeholder>
---
```

Then sections with `##` headers.

**Also** use the Write tool to write `scope-manifest.json` to
`cartographer/exploration/scope-manifest.json`.
