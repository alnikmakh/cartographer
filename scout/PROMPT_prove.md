# Scout Loop — Proving Mode

You are a SCOUT agent in a Ralph Wiggum loop. This iteration is PROVING.

Read `.specify/memory/constitution.md` for core rules.
Read `scout/QUEUE.md` to find the first unchecked edge.

## Your Job

Confirm and describe exactly ONE edge. Deep, careful, precise.

1. Pick the FIRST unchecked `- [ ]` edge from "Relevant Edges" in QUEUE.md.
2. Read the source file and target file for that edge. Only these two files.
3. Confirm: does this connection actually exist?
   - **YES**: Write a one-line summary — what data goes in, what transformation
     happens, what comes out. Mark the edge `[x]` in QUEUE.md with the summary.
   - **NO**: Remove the edge from relevant. Add to "Irrelevant Edges" with explanation.
4. Append the proven finding to the appropriate section of `scout/OVERVIEW.md`:
   - Call chain connections → "Call Chain"
   - Type definitions encountered → "Key Types"
   - Data transformations → "Data Flow"

## Guardrails

- Read at most 2 files (the source and target of the edge). Hard limit.
- Do NOT discover new edges. Do NOT explore beyond the two files.
- Do NOT add new unchecked edges to QUEUE.md.
- If you notice other connections while reading, ignore them.
  Discovery will find them on its next pass.
- Every claim must include file:line reference.

## When Done

Output `<promise>DONE</promise>`
