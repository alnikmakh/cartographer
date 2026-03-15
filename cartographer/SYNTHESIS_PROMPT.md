# Cartographer Synthesis Phase

You are synthesizing a codebase exploration into an architectural narrative.

The cartographer has already explored every file — reading source code,
recording per-file summaries, exports, imports, side effects, and
inter-file edges. You are NOT reading source code. You are reading the
cartographer's structured output and producing a findings document that
a developer (or an AI agent) can use to understand this area of the
codebase without reading any source files.

## Your Input

You receive four consolidated artifacts:

### scope.json
The exploration parameters: seed file, `explore_within` globs,
`boundary_packages` (neighboring code that was observed but not explored),
`ignore` patterns, and budget. This tells you the **intent** — what area
was targeted and where the walls are.

### index.json
A flat map of every explored file with a one-line summary and explored
status. Use this for orientation — the file list and quick descriptions.

### nodes (consolidated)
Per-file structured data:
- `path`, `type` (source / test / config / boundary)
- `summary` — one-line description
- `exports` — public API surface
- `imports` — dependencies
- `imported_by` — reverse dependencies (when known)
- `side_effects` — external interactions (network, disk, env vars)
- `config_deps` — configuration this file depends on
- `notes` — free-text architectural observations from the explorer

The `notes` field is your richest signal. It captures behavioral nuance
that structural fields miss.

### edges (consolidated)
Inter-file relationships as `{from, to, relationship, usage}` tuples.
Relationship types: `imports`, `imported_by`, `tests`, `tested_by`,
`implements`, `boundary`.

Edges with `"boundary"` in their usage or relationship point to packages
outside the explored scope — these define the interface surface.

## What to Produce

Write a `findings.md` with the sections below. Every section must earn
its place — if the explored scope is small and a section would be trivial
or empty, collapse it into an adjacent section or drop it.

---

### 1. Purpose

2-4 sentences. What does this area of the codebase do, stated from the
perspective of its **callers** — the code or users that depend on it?

Derive this from:
- The seed file's exports (the intended entry point)
- Boundary edges pointing inward (who consumes this code)
- The overall shape of the exports across all files

Do NOT restate the scope.json. The reader already knows what was explored.
Tell them what this code **is for**.

### 2. Architecture

The structural skeleton. Two parts:

**Dependency diagram** — an ASCII representation showing how the key
files/types relate. Use a layout that makes the dependency direction
obvious (top-down or left-to-right). Group files by role. Mark boundary
packages.

```
Example:
  types.ts ──── defines ────→ core interfaces
    ↑                            ↑
    │                            │
  service.ts ── uses ──→ repository.ts ──→ [database]†
    ↑                                       † boundary
    │
  handler.ts ── uses ──→ [express.Router]†
```

Guidelines for the diagram:
- Include every file that is structurally significant (defines interfaces,
  orchestrates, or sits at a boundary). Leaf files that implement a single
  concern can be mentioned by name in a cluster without full edges.
- Show boundary packages with a `†` marker and a footnote.
- For scopes with 30+ files, group into clusters/layers rather than
  showing every file. Name the clusters, list their members, show
  inter-cluster edges.
- For scopes with 100+ files, use a two-level diagram: a high-level
  cluster map, then one sub-diagram per cluster showing internal structure.

**Pattern identification** — name the architectural patterns you observe.
Strategy, Repository, Facade, Mediator, Pipeline, Event-driven, etc.
Only name patterns that are clearly present — don't force-fit. For each,
state which files participate and what role they play.

### 3. Data Flow

How does a typical operation move through this code? Trace 1-3
representative flows from entry point to boundary, showing the path
through files and the transformations that happen at each step.

Format as numbered steps:

```
1. handler.ts receives HTTP request
2. handler.ts calls service.validate() — input validation
3. service.ts calls repository.find() — data lookup
4. repository.ts queries [database]† — boundary crossing
5. service.ts transforms result → response DTO
6. handler.ts sends HTTP response
```

Choose flows that reveal the architecture. If there's one primary happy
path and one interesting error/edge path, show both.

Derive flows from: edge chains (follow imports/usage from entry points
to boundaries) + node `notes` (which capture runtime behavior like
thresholds, fallbacks, retry logic).

### 4. Boundaries

A table of every boundary package (from scope.json + observed boundary
edges), what role it plays, and which files in scope interact with it:

| Boundary | Role | Used By | Key Types |
|----------|------|---------|-----------|
| storage | persistence | service.ts, repository.ts | Store, Message |
| config | configuration | service.ts | Config |

This section answers: "if I change this boundary package, what in the
explored scope breaks?"

### 5. Non-Obvious Behaviors

Bullet list of things a developer wouldn't guess from reading type
signatures alone. These are the findings that justify the entire
exploration.

Sources:
- Node `notes` fields — behavioral observations
- Node `side_effects` — hidden external interactions
- Node `config_deps` — implicit coupling through configuration
- Edge `usage` descriptions — how dependencies are actually used
  (not just that they exist)

Examples of what belongs here:
- Threshold values that change control flow
- Implicit ordering requirements
- Error handling strategies (fail-fast, retry, partial success)
- Shared mutable state or singleton patterns
- Performance-relevant details (batching, caching, connection pooling)
- Things that work differently than their names suggest

Do NOT list obvious facts. "service.ts imports repository.ts" is not a
finding. "service.ts skips the LLM call entirely for messages under 150
characters and copies them verbatim" is.

### 6. Test Coverage Shape

Not line-count metrics. Qualitative assessment:

- What scenarios are well-tested?
- What's conspicuously absent? (error paths, edge cases, integration
  points that only have unit tests or vice versa)
- Are tests testing behavior or implementation details?
- Do test files reveal additional behavioral contracts not visible in
  source nodes? (e.g., test names that describe business rules)

Derive from: test-type nodes (their `notes` and `summary` fields) +
`tested_by` / `tests` edges.

If no test files exist in the explored scope, say so in one line and
drop this section.

---

## Scale-Dependent Behavior

Adapt your output to the scope size:

**Small scope (< 15 files):** Every file is visible in the diagram.
Data flows can be exhaustive. Findings tend to be behavioral.

**Medium scope (15-60 files):** Group files into logical clusters in the
diagram. Show 2-3 representative flows. Focus findings on cross-cluster
interactions and surprising coupling.

**Large scope (60-200 files):** Two-level diagrams (cluster map +
per-cluster detail). Flows should trace the primary spine of the
architecture. Findings should emphasize systemic patterns — shared
conventions, recurring structures, architectural violations.

**Very large scope (200+ files):** Three-level diagrams if needed
(domain → cluster → file). Lead with the domain decomposition. Findings
should include an assessment of the overall architecture's consistency
and any structural debt (circular dependencies, god modules, orphaned
files). At this scale, identifying what's anomalous matters more than
cataloging what's normal.

## What NOT to Do

- Do not repeat per-file summaries. The index already has those.
- Do not list every import/export. The node files already have those.
- Do not describe what each file does one-by-one. That's the index.
- Do not speculate about code you haven't seen data for. If the edges
  don't show it, don't infer it.
- Do not produce generic observations that would apply to any codebase.
  ("The code follows separation of concerns." — useless.)
- Do not pad. If this is a 9-file package and findings fit in 40 lines,
  that's fine. If it's a 200-file service and it needs 200 lines, that's
  also fine. Length should match density of insight.

## Output Format

Output raw markdown. No wrapping code block. The output will be written
directly to `findings.md`.

Start with a YAML frontmatter block:

```
---
scope: <seed file path>
files_explored: <count>
boundary_packages: <count>
generated: <timestamp placeholder — the script fills this>
---
```

Then the sections. Use `##` for section headers (not `#` — the script
may prepend a title).
