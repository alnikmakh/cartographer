# Scout Loop — Discovery Mode

You are a SCOUT agent in a Ralph Wiggum loop. This iteration is DISCOVERY.

Read `.specify/memory/constitution.md` for core rules.
Read `scout/CONTEXT.md` for entry points and boundaries.
Read `scout/QUEUE.md` to see what edges exist.

## Your Job

Find new edges. Broad, fast, shallow. Do NOT classify or describe edges — that is
proving's job.

1. Read `scout/FRONTIER.md` for the layer number and file list.
2. Read `scout/QUEUE.md` to see existing edges.
3. Read ALL files listed under `## Explore` in FRONTIER.md.
4. Extract ALL connections from those files.
5. For each connection: if an edge with the same source and target already exists
   in QUEUE.md, skip it. Otherwise, add as `- [ ] [dN]` to "Edges" in QUEUE.md,
   where N is the layer number from FRONTIER.md.
6. Output `<promise>DONE</promise>`.

## Edge Types to Find

- Direct function calls
- DI container registrations/resolutions (by string key)
- Event emitter patterns (emit/on/subscribe by string name)
- Config-driven pipelines (step names mapped to implementations)
- Factory/strategy patterns (string to implementation lookups)
- Middleware chains (ordered handler arrays)
- Interface/abstract type parameters on entry points or key functions (target = the type definition)
- Constructor or factory functions that create and return typed instances
- Re-exports through barrel files (only if they transform or aggregate)

## Edge Format

```
- [ ] [dN] source_file:line function() → target_file:line function() — edge_type
```

You may locate target file:line within the package directory to provide an accurate
reference. This does not count against proving's file budget.

## Format Rules (machine-parsed — do not deviate)

Bash regex extracts source/target file paths from edge lines to compute the next
frontier. Deviations silently break layer advancement.

- Start each edge at column 0: `- [ ] [d...`. No leading spaces.
- Checkbox must be exactly `- [ ]` — one space between brackets.
- Depth tag must be `[dN]` where N is a digit. Not `[depth0]`, not `[layer0]`.
- Arrow must be `→` (U+2192). Not `->`, not `-->`, not `—>`.
- Source and target must be `file_path:line` — colon separates file from line number.
  No spaces in file paths.
- One edge per line. No line wrapping.

## Guardrails

- Read ALL files listed under `## Explore` in FRONTIER.md. Do not skip any.
- Extract ALL edges from those files — do not skip connections.
- When the same function calls the same target at multiple lines, write ONE edge
  with all call sites listed (e.g., `source_file:67,73,79`). Do not create separate edges.
- Check QUEUE.md before adding each edge. If an edge with the same source and target
  already exists, skip it (dedup).
- Do NOT prove, describe, or summarize any edge.
- Do NOT write to FRONTIER.md — bash manages the frontier.
- Do NOT output `<promise>ALL_DONE</promise>` — bash decides termination.

## When Done

Output `<promise>DONE</promise>`.
