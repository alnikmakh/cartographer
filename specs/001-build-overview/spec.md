# Specification: Build Explanation Map

## Overview

Explore a codebase starting from defined entry points within defined boundaries.
Build a complete explanation map in scout/OVERVIEW.md using a queue-based
discovery/proving workflow. The output must be self-contained — a reader should
understand the full structure without opening any source files.

## How It Works

The bash loop (`run-scout.sh`) controls mode selection, not the agent.

1. Script reads scout/QUEUE.md, counts unchecked `- [ ]` edges
2. If unchecked > 0 → agent receives PROMPT_prove.md
3. If unchecked = 0 → agent receives PROMPT_discover.md
4. Agent does its job, outputs `<promise>DONE</promise>`
5. Script loops back to step 1

The agent never decides its own mode. It receives one prompt, does one thing.

Discovery exits the loop by outputting `<promise>ALL_DONE</promise>` when
no frontier remains (all proven edge targets have been explored, no new
connections found).

---

## Queue Format

### Relevant Edges

```
- [ ] [d3] api/handler.ts:38 createInvoice → billing/service.ts:55 processInvoice — call
- [x] [d1] billing/service.ts:55 processInvoice → billing/validator.ts:22 validate — call
      SUMMARY: receives RawInvoice object, validator strips unknown fields, returns ValidatedInvoice
```

### Irrelevant Edges

```
- billing/service.ts:60 processInvoice → logger.ts:12 log — SKIPPED: structured JSON logger that writes request context (invoice ID, amount, user) to stdout for observability. Not explored because logging does not transform data.
- billing/service.ts:63 processInvoice → metrics.ts:8 increment — SKIPPED: Prometheus counter that tracks invoice creation rate by currency. Outside boundaries (packages/analytics).
```

---

## Guardrails

### Depth Limit

Every edge must include its depth [dN] from the nearest entry point.
Do NOT add edges beyond the max depth specified in scout/CONTEXT.md.

### Boundary Enforcement

Only discover edges that lead to files within the boundaries defined in scout/CONTEXT.md.
If an edge crosses into a forbidden package, add it to irrelevant with "outside boundary" reason.

### File Budget

- Discovery: at most 2 frontier files per iteration. Extract ALL edges from them.
- Proving: at most 2 files per iteration. Prove ALL unchecked edges sharing the same source file.

---

## Acceptance Criteria

- [ ] Every relevant edge has file:line references on both source and target
- [ ] Every proven edge has a data-flow summary
- [ ] Irrelevant edges explain what the call does AND why it was skipped
- [ ] All irrelevant edges are copied into OVERVIEW.md "Noted but Not Explored"
- [ ] OVERVIEW.md is self-contained — reader needs no source files
- [ ] OVERVIEW.md is verbose — each edge has full context, not one-liners
- [ ] All paths between entry points are traced within boundaries
- [ ] DI, event, config, middleware indirection is followed, not skipped
- [ ] No unexplored frontier remains within boundaries and depth limit
