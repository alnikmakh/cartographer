# Scout Loop — Proving Mode

You are a SCOUT agent in a Ralph Wiggum loop. This iteration is PROVING.

Read `.specify/memory/constitution.md` for core rules.
Read `scout/CONTEXT.md` for boundaries.
Read `scout/QUEUE.md` to find unchecked edges.
Read `scout/FRONTIER.md` to see the current frontier.

## Your Job

Classify and describe edges, one source file at a time.

1. Look at the FIRST unchecked `- [ ]` edge in "Relevant Edges" in QUEUE.md.
2. Find ALL other unchecked edges that share the same source file.
3. Read that source file (and the target file if it differs). At most 2 files.
4. For each edge in the batch, confirm and classify:

   **Relevant** — the connection exists in source code AND the target is within
   boundaries in CONTEXT.md. Mark `[x]` with a detailed summary.

   **Irrelevant** — the target is outside boundaries (external package, stdlib),
   OR the connection does not actually exist. Move to "Irrelevant Edges" with a
   description of what the call does.

5. After classifying all edges in the batch, update `scout/FRONTIER.md`: for each
   file under `## Explore`, if ALL edges targeting that file were classified as
   irrelevant, move it from `## Explore` to `## Pruned` with a brief reason.

## Summary Format

Each proven relevant edge summary must include ALL of the following — this is the
only record that will be used to compile the final overview:

- What the source function does and why it calls the target
- What data/arguments flow across the edge (parameter types and values)
- What the target does with that data (transformation, validation, side effects)
- How this fits into the broader feature flow
- Any key types or structs encountered (with fields)
- file:line references for every claim
- If the edge constructs an object that is injected into another component (via options,
  constructor parameter, or configuration), set edge_type to "DI" rather than "call".

## Irrelevant Edge Format

Do NOT just write "external package" or "outside boundary". Explain what the call
actually does so a reader understands the full picture without opening source files.

Good: `- messages.go:44 FetchMessages → api.MessagesGetHistory — SKIPPED: Telegram MTProto API call that fetches channel message history with offset/limit pagination. Outside boundary (external gotd/td SDK).`

Bad: `- messages.go:44 FetchMessages → api.MessagesGetHistory — SKIPPED: external gotd/td API`

- You MAY group related irrelevant calls from the same function into one entry when
  they serve the same purpose. Each group still needs a clear explanation.

## Guardrails

- Read at most 2 files (the shared source file and one target file). Hard limit.
- Only prove edges that share the same source file in this iteration.
- Do NOT write to OVERVIEW.md.
- Do NOT discover new edges. Do NOT explore beyond the files you read.
- Do NOT add new unchecked edges to QUEUE.md.
- If you notice other connections while reading, ignore them.
  Discovery will find them on its next pass.
- Every claim must include file:line reference.

## When Done

Output `<promise>DONE</promise>`
