# Cross-Scope Synthesis

You are reviewing a codebase that has been explored scope-by-scope. Each
scope has a **manifest** (machine-readable summary) and **findings**
(human-readable architectural narrative). You also have the AST dependency
graph showing cross-scope edges.

## Your Job

You are NOT compiling a summary. The per-scope findings already describe
each scope well. Your job is adversarial cross-cutting analysis:

1. **Find cross-scope inconsistencies, contradictions, blind spots.**
   Does scope A's manifest claim it "guarantees X" while scope B's
   findings show it handles X-failure? Do two scopes both claim to own
   the same entity?

2. **Trace key entities across scope boundaries.**
   Follow types, interfaces, and data through the touchpoints declared
   in scope manifests. Where do contracts tighten or loosen? Where does
   data transform in ways the consuming scope may not expect?

3. **Identify systemic patterns (or violations thereof).**
   Do all scopes follow the same error handling strategy? The same
   config pattern? Where does one scope break a convention the others
   follow?

4. **Assess architectural health at the system level.**
   Are scope boundaries well-placed? Is there orphaned code? Circular
   dependencies? God scopes that everything depends on? Scopes that
   should be merged or split?

## Your Input

### Scope Manifests
One `scope-manifest.json` per scope. Contains: purpose, exposed types
and interfaces, consumed dependencies, cross-scope touchpoints,
invariants, risks, and patterns. These are compact and machine-readable —
use them for systematic cross-referencing.

### Scope Findings
One `findings.md` per scope. Contains: architectural narrative, dependency
diagrams, data flows, boundary analysis, non-obvious behaviors, test
coverage shape. Use these for deeper context when the manifest flags
something worth investigating.

### CGC Cross-Scope Graph
AST-parsed dependency edges between scopes. Shows which files in scope A
import which files in scope B. Ground truth for structural coupling.

### Source Access
You have read access to all source files. Use it to verify cross-scope
claims — especially at boundary crossings where two scopes meet.

## What to Produce

Write `architecture.md` with these sections:

### 1. System Map

How scopes relate to each other. Build from the cross-scope touchpoints
in manifests + the CGC graph edges. Show:
- Which scopes depend on which
- The direction and nature of each dependency
- Shared types or interfaces that cross boundaries

Use an ASCII diagram showing scope-level relationships.

### 2. Data Lineage

Pick the 2-5 most important entities (types, data structures) and trace
them across scope boundaries. For each:
- Where is it defined?
- Which scopes consume it?
- How does it transform at each boundary?
- Are there contract mismatches?

### 3. Cross-Scope Findings

The adversarial analysis. For each finding:
- What's the inconsistency, contradiction, or blind spot?
- Which scopes are involved?
- What's the evidence (cite manifest fields, findings sections, or source)?
- What's the risk?

This is the highest-value section. Be specific and cite evidence.

### 4. Systemic Patterns

Conventions that hold or break across scopes:
- Error handling strategy
- Config management approach
- Logging and observability patterns
- Test strategy
- Naming conventions
- Dependency injection approach

For each pattern, note which scopes follow it and which deviate.

### 5. Architectural Assessment

System-level health:
- Are scope boundaries well-placed? (aligned with domain boundaries,
  minimal cross-scope coupling)
- Structural debt: circular dependencies, God scopes, orphaned code
- Missing scopes: areas of the codebase not covered by any scope
- Scalability concerns: bottleneck scopes, single points of failure

## Output Format

Your text output is captured as the architecture document. Do NOT use any
write tools — just output the markdown directly as your response text.
Do not wrap the output in code blocks. Do not add preamble or commentary.
Your entire text response becomes `architecture.md`.

Start with YAML frontmatter:

```
---
scopes_analyzed: <count>
generated: <timestamp>
---
```

Then the sections. Use `##` for section headers. Be concise but precise.
Every claim must reference evidence (scope manifest field, findings
section, or source file location).

Do NOT rehash individual scope findings. The reader has those. Focus
exclusively on cross-cutting analysis that no single scope could produce.
