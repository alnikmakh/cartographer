# Redundancy Analysis: Cartographer with Pre-Phase

With the pre-phase producing a complete scope.json (explore_within,
boundary_packages, ignore, budget — all decided by human + AI
brainstorming), the following cartographer components lose their
purpose.

## explore.sh — Functions

### Redundant

**`complete_scope()`** (~120 lines, lines 312–435)
Auto-fills missing scope.json fields: discovers boundaries from
sibling directories, detects ignore patterns from file extension,
fills default budget. Pre-phase produces a complete scope.json —
nothing to fill.

**`discover_boundaries()`** (~25 lines, lines 259–285)
Finds sibling directories of explore_within target. Pre-phase
determines boundaries through structural analysis, not filesystem
adjacency.

**`detect_ignore_patterns()`** (~20 lines, lines 288–310)
Guesses ignore globs from seed file extension (.mjs → skip .d.ts,
.ts, .css). Pre-phase sets ignores explicitly.

**`--init` mode** (~55 lines, lines 449–503)
Orchestrates complete_scope + discover_scope_files +
init_exploration. With the three functions above gone, this reduces
to: glob files, create state files. That's ~10 lines inlined into
the main script, not a separate mode.

### Surviving

- `queue_pending_count()` — loop termination
- `is_budget_exhausted()` — safety cap
- `sanitize_node_name()` — file naming
- `detect_completion()` — signal parsing
- `init_exploration()` — creates state files (queue, index, stats, findings)
- `discover_scope_files()` — globs filesystem for explore_within matches
- Main loop, provider setup, logging, banner — all still needed

## explore.sh — Tests

### Redundant (test functions for removed code)

- `test_complete_scope_writes_valid_json`
- `test_complete_scope_preserves_seed`
- `test_complete_scope_adds_boundaries`
- `test_complete_scope_fills_budget`
- `test_complete_scope_string_seed`
- `test_discover_finds_siblings`
- `test_discover_excludes_scope_dir`
- `test_discover_no_siblings`
- `test_discover_missing_parent`
- `test_ignore_js`
- `test_ignore_go`
- `test_ignore_unknown`
- `test_init_mode_integration` (tests --init orchestration)

That's 13 of 37 test assertions gone.

### Surviving

All tests for queue_pending_count, is_budget_exhausted,
sanitize_node_name, detect_completion, init_exploration,
discover_scope_files.

## PROMPT.md — Agent Instructions

### Redundant

**Tier classification rules** (lines 14–34)
The agent currently decides per-discovered-file: is this tier 1, 2,
or 3? With pre-queuing from a complete scope.json, all tier-1 files
are already in the queue. The agent doesn't classify — it just
explores what's queued and records references to anything outside
scope as boundary or external.

**Depth tracking and tier demotion** (lines 36–42)
"When a node's depth reaches max_depth_from_seed, treat everything
it discovers as tier 2." Depth is meaningful when exploring outward
from a seed. When all tier-1 files are pre-determined, there is no
outward expansion. Depth is unused.

**Priority signals** (lines 136–143)
HIGH/MEDIUM/LOW priority guided which files to explore first when
budget might run out before finishing. If the job is "describe all
files in scope," order doesn't matter. The queue is a checklist.

**Discovery steps in exploration** (step 4, line 83)
"Classify each discovered file by tier" — agent no longer classifies.
It explores queued files and notes what they reference.

### Surviving

- Identity and purpose (lines 1–8)
- Read scope/queue/index/stats at start
- Don't read nodes/ and edges/ directories at start
- Neighbor loading rules (when to read a neighbor's node file)
- Per-file exploration steps (read source, identify exports/imports/
  side effects, write node + edges, update index/queue/stats)
- Save-after-each-file discipline
- Per-iteration budget (2–6 files)
- Exit condition signals (MAP_COMPLETE, BUDGET_REACHED, CONTEXT_FULL)

## Summary

| Component | Lines | Status |
|---|---|---|
| `complete_scope()` | ~120 | remove |
| `discover_boundaries()` | ~25 | remove |
| `detect_ignore_patterns()` | ~20 | remove |
| `--init` mode | ~55 | replace with simple glob + init |
| PROMPT.md classification | ~30 | simplify |
| PROMPT.md depth/priority | ~15 | remove |
| Tests for removed code | 13 assertions | remove |
