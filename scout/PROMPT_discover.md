# Scout Loop — Discovery Mode

You are a SCOUT agent in a Ralph Wiggum loop. This iteration is DISCOVERY.

Read `.specify/memory/constitution.md` for core rules.
Read `scout/CONTEXT.md` for entry points, boundaries, and max depth.
Read `scout/OVERVIEW.md` to understand what is already known.
Read `scout/QUEUE.md` to see what edges exist.

## Your Job

Find new edges. Broad, fast, shallow. Do NOT classify or describe edges — that is
proving's job.

1. Check `scout/FRONTIER.md`.
   - If it says "ENTRY_POINTS", start from the entry points in CONTEXT.md.
   - If `## Explore` lists files, those are your frontier — read up to 2 of them.
   - If `## Explore` is empty or FRONTIER.md says "EMPTY", skip to "If No Frontier
     Exists" below.
2. Read the frontier files.
3. Extract ALL connections from those files. Add each as unchecked `- [ ]` to
   "Relevant Edges" in QUEUE.md. Do not classify or filter — proving decides
   what is relevant.
4. Be thorough within the files you read. Extract every connection, not just obvious ones.
5. Only identify what connects to what. Do NOT read deeply into targets.

## After Adding Edges

Write the next frontier to `scout/FRONTIER.md` under `## Explore`. List target files
from the NEW edges you just added, one per line, even if the file was read before —
it may contain deeper functions to explore next iteration. Only include files that
can be read (within the repo, not external packages). Keep any existing `## Pruned`
section unchanged.

If you found no new edges, leave `## Explore` empty.

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
- [ ] [dN] source_file:line function → target_file:line function — edge_type
```

## Guardrails

- Read ALL frontier files (or all entry point files if FRONTIER.md says "ENTRY_POINTS").
- Extract ALL edges from those files — do not skip connections.
- d0 = the source function is an entry point listed in CONTEXT.md. dN = the source
  function is a target of a d(N-1) edge. Depth is per-function, not per-file — if a file
  contains both entry points and non-entry-point functions, only edges from the entry
  point functions are d0.
- Do NOT add edges beyond max depth in CONTEXT.md.
- When the same function calls the same target at multiple lines, write ONE edge
  with all call sites listed (e.g., `source_file:67,73,79`). Do not create separate edges.
- Do NOT prove, describe, or summarize any edge.

## If No Frontier Exists

`## Explore` is empty or FRONTIER.md says "EMPTY" → output `<promise>ALL_DONE</promise>`.

## When Done

If you added new edges, write the next frontier and output `<promise>DONE</promise>`.

If you found NO new edges, leave `## Explore` empty and output
`<promise>DONE</promise>` — the next iteration will ALL_DONE.
