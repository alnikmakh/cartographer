# Auto Pre-Phase: Non-Interactive Scope Analysis

## What This Is

You are running in **auto mode** — no user interaction. Analyze the
provided repomix structural output and produce all slices autonomously.

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

## What You're Reading

Repomix structural output: source files stripped to imports and
exported symbols via Tree-sitter.

**Sufficient for:**
- Which files depend on which packages
- Clusters of files that import from each other
- Shared dependencies across packages
- Entry points (index files, main files, CLI handlers)
- Feature-aligned groupings

**Not sufficient for:**
- Runtime behavior, event flows, dynamic dispatch
- What functions actually do internally
- Implicit coupling through shared state or config

That's fine. Detailed tracing is cartographer's job. Your job is
deciding WHERE cartographer should look.

## What to Look For

**Import clusters.** Files that heavily import from each other form
natural slices. Tight A→B→C→D with few connections to E→F→G suggests
two separate slices.

**Fan-out points.** A file importing from 8+ packages is either an
orchestrator (good seed) or a god file (slice carefully around it).

**Shared dependencies.** Packages X, Y, Z all depend on W → W is
likely a boundary, and X/Y/Z may be separate slices each needing W
at the wall.

**Entry points.** Index files, main files, route handlers, CLI
commands — natural seeds for cartographer. They point outward.

**Barrel files / re-exports.** Structural hubs that reveal public
API. Good seeds because they reference everything without being
interesting themselves.

**Missing packages.** Imports pointing to packages NOT in the current
repomix output. Flag these in your output.

## Cluster Detection Method

Use this concrete process to identify natural slices:

1. **List each file's internal imports.** For every file in the
   structural output, note which other in-scope files it imports.
2. **Group by shared imports.** Files sharing 3+ internal imports
   belong to one cluster. Name the cluster after its dominant
   directory or purpose.
3. **Find bridges.** A file imported by two clusters is a boundary
   candidate. It connects the clusters without belonging to either.
4. **Detect import chains.** A→B→C→D within one directory tree is
   one slice. The chain head is a natural seed.
5. **Check fan-out.** A file importing 8+ packages is an
   orchestrator — good seed. Its dependencies become boundaries.
6. **Verify isolation.** If >30% of a cluster's imports cross the
   proposed boundary, the boundary is wrong. Widen or restructure.

## How Your Output Gets Used

Each slice becomes input to **cartographer** — an autonomous agent
that maps file-level dependency graphs by reading actual source code
one file at a time. Cartographer needs a `scope.json`:

```json
{
  "seed": "path/to/entry-point.ts",
  "boundaries": {
    "explore_within": ["path/to/package/**"],
    "boundary_packages": ["path/to/neighbor", "..."],
    "ignore": ["**/*.test.ts", "**/*.md"]
  },
  "budget": {
    "max_iterations": 20,
    "max_nodes": 60,
    "max_depth_from_seed": 5
  },
  "hints": [
    "Observations about patterns to watch for during exploration"
  ]
}
```

## Budget Sizing

Use this table to set budget values based on file count:

| File count | max_nodes | max_iterations | max_depth_from_seed |
|---|---|---|---|
| 1-10 | count + 2 | ceil(count/3) + 2 | 3 |
| 11-30 | count + 5 | ceil(count/3) + 3 | 5 |
| 31-60 | count + 10 | ceil(count/3) + 5 | 6 |
| 61-100 | count + 15 | ceil(count/3) + 7 | 7 |
| 100+ | count + 20 | ceil(count/3) + 10 | 8 |

## Your Process

1. Read the repomix structural output provided to you
2. Apply the cluster detection method to identify all natural slices
3. For each slice, determine:
   - Name, thesis, seed, explore_within, boundary_packages, ignore
   - Budget (using the sizing table above)
   - Hints about coupling and patterns
4. Validate file counts by running `find` on proposed explore_within
   globs (exclude ignore patterns)
5. Write `cartographer/prephase/slices.json` with all slices
   (status: "proposed")
6. Write individual scope files to
   `cartographer/prephase/scopes/<slug>/scope.json` for each slice
7. Suggest an execution order

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
**Budget:** max_nodes=<N>, max_iterations=<N>, max_depth=<N>
```

Then print the execution order as a numbered list.

The user will review slices.json and accept/reject before running
cartographer.
