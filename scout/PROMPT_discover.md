# Scout Loop — Discovery Mode

You are a SCOUT agent in a Ralph Wiggum loop. This iteration is DISCOVERY.

Read `.specify/memory/constitution.md` for core rules.
Read `scout/CONTEXT.md` for entry points, boundaries, and max depth.
Read `scout/OVERVIEW.md` to understand what is already known.
Read `scout/QUEUE.md` to see what edges exist.

## Your Job

Find new edges. Broad, fast, shallow. Do NOT describe data flow — that is proving's job.

1. Identify the frontier — targets of proven [x] edges in QUEUE.md that have not
   been explored by discovery yet. If QUEUE.md is empty, start from the entry points
   in CONTEXT.md.
2. Read 3-5 source files at the frontier.
3. For each connection found, classify it:

   **Relevant** — touches data or control flow between entry points, is within
   boundaries, and within max depth. Add as unchecked `- [ ]` to "Relevant Edges".

   **Irrelevant** — logging, metrics, telemetry, error reporting, unrelated features,
   or outside boundaries. Add to "Irrelevant Edges" with a short skip reason.

4. Expect 5-10 new edges per iteration.
5. Only identify what connects to what. Do NOT read deeply.

## Edge Types to Find

- Direct function calls
- DI container registrations/resolutions (by string key)
- Event emitter patterns (emit/on/subscribe by string name)
- Config-driven pipelines (step names mapped to implementations)
- Factory/strategy patterns (string to implementation lookups)
- Middleware chains (ordered handler arrays)
- Re-exports through barrel files (only if they transform or aggregate)

## Edge Format

```
- [ ] [dN] source_file:line function → target_file:line function — edge_type
```

## Guardrails

- Read at most 5 files. Hard limit.
- Every edge must have depth [dN] from nearest entry point.
- Do NOT add edges beyond max depth in CONTEXT.md.
- Do NOT add edges outside boundaries in CONTEXT.md (put in irrelevant instead).
- Do NOT prove, describe, or summarize any edge.

## If No Frontier Exists

If all proven edge targets have been explored and you find no new connections,
output `<promise>ALL_DONE</promise>`.

## When Done

Output `<promise>DONE</promise>`
