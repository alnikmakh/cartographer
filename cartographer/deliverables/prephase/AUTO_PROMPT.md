# Auto Pre-Phase: Non-Interactive Scope Analysis (Graph Mode)

## What This Is

You are running in **auto mode** — no user interaction. Query the
CodeGraphContext dependency graph via MCP tools and produce all
slices autonomously.

The user will review your output afterward and accept/reject slices
before running cartographer.

## Prior Exploration Data

Check for prior cartographer output before proposing slices:

- If any `exploration/index.json` from prior runs exists, read it.
  Files with explored: true are already mapped territory.
- If `prephase/slices.json` exists, check for status: "explored".
  Their boundary_packages are known — you can suggest slices that
  extend from mapped areas.
- Note which boundary packages are now fully explored and could
  become explore_within in a new slice.

## What You're Querying

You have access to a CodeGraphContext dependency graph via MCP tools.
The graph was built from tree-sitter AST parsing — it contains files,
modules, functions, classes, and their import/call/inheritance edges.

**MCP tools available:**

- `find_code` — search by name or fuzzy text
- `analyze_code_relationships` — call graphs, dependencies, reverse
  lookups, fan-in/fan-out (the main workhorse)
- `execute_cypher_query` — run read-only Cypher queries against the
  graph DB for anything the higher-level tools don't cover
- `get_repository_stats` — file/class/function counts
- `find_most_complex_functions` — complexity hotspots
- `find_dead_code` — unused functions
- `add_code_to_graph` — index additional paths on the fly

**Sufficient for:**
- Precise dependency edges between files and modules
- Fan-out / fan-in counts per file or function
- Import chains and transitive dependencies
- Entry point identification (files with no inbound imports)
- Hub detection (files with most inbound dependencies)
- Class hierarchies and inheritance trees
- Connected component analysis via Cypher

**Not sufficient for:**
- Runtime behavior, event flows, dynamic dispatch
- What functions actually do internally
- Implicit coupling through shared state or config

That's fine. Detailed tracing is cartographer's job. Your job is
deciding WHERE cartographer should look.

## What to Look For

**Import clusters.** Query groups of files that heavily depend on
each other. Tight A→B→C→D with few connections to E→F→G suggests
two separate slices.

**Fan-out points.** Use `analyze_code_relationships` to find files
with 8+ outbound dependencies — either an orchestrator (good seed)
or a god file (slice carefully around it).

**Shared dependencies.** Query which files are imported by the most
other files. These are likely boundaries.

**Entry points.** Files with no inbound imports within scope —
natural seeds for cartographer.

**Missing packages.** Imports pointing to packages not in the graph.
Flag these in your output.

## Cluster Detection Method

Use this graph-native process to identify natural slices:

1. **Query entry points.** Find files with no inbound imports within
   scope — these are natural starting points.
2. **Query fan-in hubs.** Find files with the most inbound
   dependencies — these are likely boundaries between areas.
3. **Trace connected components.** For each entry point, follow
   transitive imports. Files reachable without crossing a hub form
   one cluster.
4. **Find bridges.** Files imported by multiple clusters are boundary
   candidates. Query inbound edges and count cluster membership.
5. **Measure fan-out.** For candidate seeds, query direct
   dependencies. 8+ packages = orchestrator.
6. **Verify isolation.** For each proposed cluster, query what
   percentage of edges cross the boundary. >30% = wrong boundary.

## How Your Output Gets Used

Each slice becomes input to **cartographer** — an autonomous agent
that maps file-level dependency graphs by reading actual source code
one file at a time. Cartographer needs a `scope.json`:

```json
{
  "seed": "path/to/entry-point.ts",
  "boundaries": {
    "explore_within": ["path/to/package/**"],
    "boundary_packages": ["path/to/neighbor", "..."]
  },
  "hints": [
    "Observations about patterns to watch for during exploration"
  ]
}
```

Do NOT add a `budget` field. The exploration script computes its own
iteration limits from the file count at runtime.

## Your Process

1. Query `get_repository_stats` to understand codebase size
2. Query entry points — files with no inbound imports
3. Query fan-in hubs — most-imported files
4. Use `analyze_code_relationships` and `execute_cypher_query` to
   trace connected components from entry points
5. Apply cluster detection method to identify natural slices
6. For each slice, determine:
   - Name, thesis, seed, explore_within, boundary_packages
   - Hints about coupling and patterns
7. Validate file counts by querying the graph for files matching
   proposed explore_within paths
8. Write `cartographer/prephase/slices.json` with all slices
   (status: "proposed", extraction_mode: "cgc")
9. Write individual scope files to
   `cartographer/prephase/scopes/<slug>/scope.json` for each slice
10. Suggest an execution order

## Slice Execution Order

After identifying all slices, suggest an execution order:

1. **Dependencies first** — if slice A's boundary_packages include
   packages that are slice B's explore_within, run B first.
2. **Foundation before features** — shared utilities, config, types
   before business logic.
3. **Smaller before larger** — quick wins build boundary coverage.

## Output Format

For each slice, print:

```
### <Name>

**Thesis:** <what we're trying to understand>
**Seed:** <path> — <why>
**Explore within:** <glob list>
**Boundaries:** <package list>
**Hints:** <observations>
**File count:** <N>
```

Then print the execution order as a numbered list.

The user will review slices.json and accept/reject before running
cartographer.
