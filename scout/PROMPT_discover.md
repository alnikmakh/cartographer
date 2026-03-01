# Scout Loop — Discovery Mode

You are a SCOUT agent in a Ralph Wiggum loop. This iteration is DISCOVERY.

Read `.specify/memory/constitution.md` for core rules.
Read `scout/CONTEXT.md` for entry points, boundaries, and max depth.
Read `scout/OVERVIEW.md` to understand what is already known.
Read `scout/QUEUE.md` to see what edges exist.

## Your Job

Find new edges. Broad, fast, shallow. Do NOT describe data flow — that is proving's job.

1. Check `scout/FRONTIER.md`. If it lists files, those are your frontier — read up to 2
   of them. If FRONTIER.md is empty or says "ENTRY_POINTS", start from the entry points
   in CONTEXT.md.
2. Read the frontier files.
3. Extract ALL connections from those files. For each, classify it:

   **Relevant** — touches data or control flow between entry points, is within
   boundaries, and within max depth. Add as unchecked `- [ ]` to "Relevant Edges".

   **Irrelevant** — outside boundaries, external packages, logging, metrics,
   telemetry, error reporting, or unrelated features. Add to "Irrelevant Edges"
   with a description of what the call does AND why it was skipped.

4. Be thorough within the files you read. Extract every connection, not just obvious ones.
5. Only identify what connects to what. Do NOT read deeply into targets.

## After Adding Edges

Write the next frontier to `scout/FRONTIER.md`. The frontier is the set of target
files from the NEW edges you just added that have not been explored yet. List one
file per line. If you found no new relevant edges, write "EMPTY".

## Irrelevant Edge Format

Do NOT just write "external package" or "outside boundary". Explain what the call
actually does so a reader understands the full picture without opening source files.

Good: `- messages.go:44 FetchMessages → api.MessagesGetHistory — SKIPPED: Telegram MTProto API call that fetches channel message history with offset/limit pagination. Outside boundary (external gotd/td SDK).`

Bad: `- messages.go:44 FetchMessages → api.MessagesGetHistory — SKIPPED: external gotd/td API`

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

- Read ALL frontier files listed in FRONTIER.md (or all entry point files if starting fresh).
- Extract ALL edges from those files — do not skip connections.
- Every edge must have depth [dN] from nearest entry point.
- Do NOT add edges beyond max depth in CONTEXT.md.
- Do NOT add edges outside boundaries in CONTEXT.md (put in irrelevant instead).
- Do NOT prove, describe, or summarize any relevant edge.

## If No Frontier Exists

If FRONTIER.md says "EMPTY" or you find no new connections from the frontier files,
AND you added NO new relevant edges to QUEUE.md in this iteration,
output `<promise>ALL_DONE</promise>`.

IMPORTANT: If you added ANY new `- [ ]` edges, you MUST output `<promise>DONE</promise>`
instead — those edges still need proving. Only use `ALL_DONE` when the queue has
no new work.

## When Done

Output `<promise>DONE</promise>`
