# Edge Queue

## Edges

FORMAT: - [ ] [dN] source_file:line function() → target_file:line function() — edge_type
PROVEN: - [x] [dN] (same) — SUMMARY: ...

edge_type: call | DI | event | config | middleware | re-export | entry_point


## Irrelevant Edges

FORMAT: - source_file:line function() → target — SKIPPED: reason
