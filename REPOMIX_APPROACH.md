# Context-First Architecture Analysis

## Problem

In a large TS monorepo (200+ packages, 30k+ files), agents waste most of their context window rediscovering the same codebase structure every conversation. The actual reasoning — planning architectural slices, brainstorming approaches, tracing hidden coupling — gets squeezed into whatever context remains.

Separate context-building from reasoning.

## Approach

### Step 1: Extract Structure with Repomix

Strip 2-3 target packages down to imports and exported symbols. No function bodies, no implementation detail — just the structural skeleton.

```bash
repomix --include "packages/auth/**,packages/session/**" \
        --compress
```

The output is one file containing every source file's imports and public API surface.

### Step 2: Trace with a Focused Prompt

Pass the repomix output to an agent with a prompt targeting what static analysis misses:

- Config-driven behavior (feature flags, env vars, runtime switches)
- Dependency injection wiring (what gets bound to what)
- Event/message patterns (pub/sub, event emitters, message queues)
- Shared state (singletons, module-level variables, global registries)
- Dynamic imports and lazy loading
- Implicit coupling through shared types or constants

The agent reads real code (not a pre-digested summary) and traces these patterns across the package boundary.

### Step 3: Reason in a Clean Context

Open a fresh conversation. Provide:
1. The tracing output from step 2 (the discovered hidden dependencies)
2. The specific architectural question or planning task

The agent starts with full structural understanding and spends its entire context on thinking, not on grepping.

## Why This Works

- **No iteration loop** — repomix extracts structure in one shot
- **Agent reads real code** — no lossy intermediate format that might miss something
- **Minimal machinery** — no queue, no state files, no bash loop, no JSON schema
- **Scoped** — 2-3 packages at a time, not the whole monorepo
- **Disposable** — regenerate on demand, no staleness problem

## Watch For

- Context budget: 200 files of stripped source could be 50-100k tokens. Verify the agent has room left to reason after loading.
- Repomix config: tune stripping aggressively. Import lines + export signatures are enough. Internal helpers, private functions, function bodies — all noise for structural analysis.
