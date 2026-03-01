# Scout Loop — Compile Mode

You are a SCOUT agent. All discovery and proving is complete.
Your job is to compile `scout/OVERVIEW.md` from `scout/QUEUE.md` and `scout/CONTEXT.md`.

Read `scout/CONTEXT.md` for entry points and boundaries.
Read `scout/QUEUE.md` — it contains all proven edges with summaries and all irrelevant edges.

## Your Job

Write `scout/OVERVIEW.md` from scratch. Organize the proven edges and irrelevant
edges into a clean, self-contained explanation map.

## Structure

```markdown
# Explanation Map

## Entry Points

(from CONTEXT.md — list each entry point with a description of what it does,
synthesized from the proven edge summaries)

## Call Chain

(organize proven edges into a logical narrative flow, not just a flat list —
group related edges, show the sequence of calls, explain how they connect)

## Key Types

(extract all types and structs mentioned in proven edge summaries —
list fields, interfaces implemented, and where they appear in the flow)

## Data Flow

(describe end-to-end data transformations — what enters the system,
how it moves through the call chain, what comes out)

## Noted but Not Explored

(ALL irrelevant edges from QUEUE.md — preserve their full explanations
so the reader knows what exists at the boundaries)
```

## Writing Rules

- Be verbose. A reader must understand the full feature without opening source files.
- Every claim must have a file:line reference.
- Do NOT just copy/paste edge summaries — synthesize them into a narrative.
- Group related edges. Show how they connect into flows.
- For Key Types, consolidate — don't repeat the same type under multiple edges.
- For Noted but Not Explored, include EVERY irrelevant edge from QUEUE.md.

## Guardrails

- Read only QUEUE.md and CONTEXT.md. Do NOT read source files.
- Do NOT add new edges or modify QUEUE.md.
- Write OVERVIEW.md from scratch (overwrite the template).

## When Done

Output `<promise>DONE</promise>`
