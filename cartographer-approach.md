# Code Cartographer: Autonomous Codebase Exploration via Ralph Wiggum Loop

An approach for systematically mapping large codebases using Claude Code in an autonomous Ralph Wiggum loop. Designed for monorepos and large projects where the codebase is too big for any single context window.

## Core Idea

The map lives on disk, not in context. Each loop iteration reads a lightweight index, picks an unexplored node, follows every connection as deep as context allows, writes everything back to disk, and exits. Over many iterations a complete dependency graph emerges — one that no single context window could ever hold.

The loop exists precisely because the territory is bigger than the window.

## File Structure

```
your-project/
├── scripts/explore/
│   ├── explore.sh              # The main loop
│   └── PROMPT.md               # Exploration prompt
├── exploration/
│   ├── scope.json              # Boundaries, budget, tiers
│   ├── queue.json              # Unexplored leads (tier 1 only)
│   ├── index.json              # Lightweight lookup: node name + status
│   ├── stats.json              # Counts, coverage, iteration number
│   ├── findings.md             # Append-only human-readable narrative
│   ├── nodes/                  # One file per fully explored node
│   │   ├── src__services__billing.ts.json
│   │   ├── src__lib__stripe-client.ts.json
│   │   └── src__events__event-bus.ts.json
│   └── edges/                  # Edges grouped by source node
│       ├── src__services__billing.ts.edges.json
│       └── src__lib__stripe-client.ts.edges.json
└── CLAUDE.md
```

## Key Design Decisions

### Split Map, Not Monolithic

The map is split into many small files. The agent only loads what it needs for the current iteration.

**Why:** A monolithic `map.json` grows with every iteration. On the last iterations it consumes most of the context window just being read, leaving no room to actually explore. One iteration exploring `src/utils/logger.ts` doesn't need to know what was found about `src/services/billing.ts` three iterations ago.

**How:** `index.json` stays tiny regardless of map size — just a lookup table with one-line summaries. Full node details live in individual files under `nodes/`. The agent only reads a specific node file when it needs to understand a direct neighbor of what it's currently exploring.

### Three-Tier Exploration

Not every discovered file deserves the same treatment. The scope defines three tiers:

| Tier | What | Treatment | Queued? |
|------|------|-----------|---------|
| 1 — In scope | Files matching `explore_within` globs | Full exploration: read file, trace all connections, record everything | Yes |
| 2 — Boundary | Files in `boundary_packages` | Record interface only: what your code uses from it | No |
| 3 — External | Everything else | One-liner in index, zero tokens spent | No |

**Why:** Without boundaries, the queue explodes. Every node discovers 5 more, those discover 5 more. In a 200-package monorepo with 30,000 files the cartographer won't stop until the budget is drained.

### Budget Enforcement

The scope defines hard limits on iterations, total nodes, and depth from seed. The agent checks these before starting each node and stops cleanly when any limit is reached.

### Context-Aware Checkpointing

The agent saves after EACH node, not in batches. If context runs out mid-batch, unsaved work is lost. When context gets heavy, the agent checkpoints and exits. The next iteration starts fresh with just the index and queue.

## Configuration

### scope.json

```json
{
  "seed": "packages/billing/src/services/payment.ts",

  "boundaries": {
    "explore_within": [
      "packages/billing/**",
      "packages/shared/billing-types/**"
    ],
    "boundary_packages": [
      "packages/auth",
      "packages/users",
      "packages/shared/logger",
      "packages/shared/db"
    ],
    "ignore": [
      "**/node_modules/**",
      "**/*.test.*",
      "**/*.spec.*",
      "**/dist/**",
      "**/__mocks__/**",
      "packages/docs/**",
      "packages/scripts/**"
    ]
  },

  "budget": {
    "max_iterations": 20,
    "max_nodes": 150,
    "max_depth_from_seed": 8
  },

  "depth_policy": {
    "in_scope": "explore fully",
    "boundary_package": "record interface only",
    "everything_else": "record name and skip"
  }
}
```

### index.json

Stays tiny regardless of map size. One entry per discovered node:

```json
{
  "packages/billing/src/services/payment.ts": {
    "tier": 1, "explored": true, "depth": 0,
    "one_line": "Payment orchestration"
  },
  "packages/billing/src/lib/invoice-calc.ts": {
    "tier": 1, "explored": true, "depth": 1,
    "one_line": "Tax and total calculations"
  },
  "packages/auth/src/index.ts": {
    "tier": 2, "explored": true, "depth": 2,
    "one_line": "BOUNDARY — exports verifyToken, AuthUser"
  },
  "packages/shared/logger/index.ts": {
    "tier": 3, "explored": false, "depth": null,
    "one_line": "external — skipped"
  }
}
```

### queue.json

Only contains tier 1 nodes:

```json
{
  "pending": [
    {
      "node": "packages/billing/src/models/invoice.ts",
      "depth": 1,
      "priority": "high",
      "reason": "imported by payment.ts — core domain model"
    }
  ],
  "explored": [
    "packages/billing/src/services/payment.ts"
  ],
  "boundaries_recorded": 4,
  "externals_skipped": 12
}
```

### stats.json

```json
{
  "seed": "packages/billing/src/services/payment.ts",
  "started": "2026-03-07",
  "total_nodes_discovered": 47,
  "total_nodes_explored": 23,
  "total_edges": 89,
  "last_iteration": 8,
  "coverage_pct": 48.9
}
```

## Node and Edge Files

### nodes/\<sanitized-name\>.json

Full details for one explored node:

```json
{
  "path": "src/services/billing.ts",
  "type": "service",
  "summary": "Orchestrates invoice creation, payment processing, and subscription management",
  "exports": ["createInvoice", "processPayment", "BillingService"],
  "imports": ["stripe-client", "user-repository", "invoice-model", "tax-calculator"],
  "imported_by": ["api/routes/billing.ts", "jobs/monthly-billing.ts", "webhooks/stripe.ts"],
  "side_effects": ["writes to invoices table", "calls Stripe API", "emits billing.completed event"],
  "config_deps": ["STRIPE_SECRET_KEY", "BILLING_WEBHOOK_URL"],
  "notes": "Central billing logic. All payment flows go through here."
}
```

### edges/\<sanitized-name\>.edges.json

```json
[
  {"to": "src/lib/stripe-client.ts", "relationship": "imports", "usage": "calls createCheckoutSession in processPayment flow"},
  {"to": "src/events/event-bus.ts", "relationship": "emits", "usage": "emits 'billing.completed' after successful payment"},
  {"to": "src/db/tables/invoices.ts", "relationship": "writes", "usage": "INSERT after invoice generation"}
]
```

## What Counts as a Connection

The agent tracks all of these:

- Direct imports/exports
- Event emission → event listeners (follow the event name)
- Database table reads/writes (who else touches this table?)
- API endpoint → handler → service chain
- Middleware chains (what runs before this?)
- Job schedulers → job handlers
- Config values (who else reads the same env var?)
- Type/interface sharing (shared contracts)
- Test files (what tests cover this code?)
- Dynamic requires, lazy imports, factory patterns
- Pub/sub channels, message queues, WebSocket events

## The Prompt (PROMPT.md)

```markdown
## You Are a Code Cartographer

You map codebases by exploring one area at a time. The full map
lives on disk. You only load what you need for THIS iteration.

## Scope Rules (READ FIRST EVERY ITERATION)

Read `exploration/scope.json` before doing anything.

### When you discover a new file, classify it:

TIER 1 — matches an `explore_within` glob?
→ Add to queue for full exploration

TIER 2 — inside a `boundary_packages` package?
→ Do NOT add to queue
→ Create a minimal boundary node:
  {
    "path": "packages/auth/src/index.ts",
    "tier": "boundary",
    "used_exports": ["verifyToken", "AuthUser"],
    "used_by": ["packages/billing/src/middleware/auth.ts"],
    "notes": "Boundary package. Only interface recorded."
  }
→ This takes one grep, not a full exploration

TIER 3 — matches `ignore` OR not in any known package?
→ Add a one-liner to index.json:
  "packages/docs/setup.md": { "tier": "external", "explored": false }
→ Spend ZERO tokens on it

### Depth tracking
Every node has a depth (hops from seed). When a node's depth
reaches max_depth_from_seed, treat everything it discovers
as tier 2 regardless of glob match. You're at the frontier —
record interfaces, don't keep going.

### Budget enforcement
Before starting each node, check stats.json:
- total_nodes_explored >= max_nodes? → STOP
- iteration >= max_iterations? → STOP
- All tier 1 nodes explored? → STOP (even if budget remains)

When stopping for budget: save state, write a coverage
summary to findings.md, output <promise>BUDGET_REACHED</promise>

## What You Read at the Start

1. `exploration/scope.json` — boundaries and budget
2. `exploration/queue.json` — pick the highest priority item
3. `exploration/index.json` — see what's covered vs. not
4. `exploration/stats.json` — check budget

## What You DO NOT Read at the Start

- Do NOT read every file in exploration/nodes/
- Do NOT read every file in exploration/edges/
- Only read a specific node file if you need to understand
  a DIRECT NEIGHBOR of what you're currently exploring

## When to Read a Neighbor's Node File

You're exploring file A. File A imports from file B.
- If B is in index.json with explored: true, AND you need to
  understand how A connects to B → read nodes/B.json
- If B is in index.json with explored: false → just add it
  to the queue, don't read its node file (it doesn't exist)
- If you're checking who imports A → use grep on the codebase,
  don't read node files hoping to find the answer

## Exploration Steps

For each node you pick from the queue:

1. Open and read the ACTUAL SOURCE FILE
2. Identify: exports, imports, side effects, config deps
3. Search for usages: `grep -rn "from.*<filename>" src/`
4. Create `exploration/nodes/<sanitized-name>.json`
5. Create `exploration/edges/<sanitized-name>.edges.json`
6. Update `index.json` — add/update the entry (one line summary)
7. Update `queue.json` — remove this node, add new discoveries
8. Update `stats.json`

## IMPORTANT: Save After EACH Node

Don't explore 3 nodes then save. Explore one, write all files,
then explore the next. If context runs out mid-batch you lose
everything unsaved.

## Exploration Strategy

- Go BREADTH FIRST by default. Map the immediate neighborhood
  before diving deep.
- When you find an event or message bus pattern, mark it
  HIGH PRIORITY — these are invisible dependencies.
- When you find shared database tables, mark HIGH PRIORITY —
  these create implicit coupling.
- Config/env vars are LOW PRIORITY unless they control behavior
  branching.

## Per Iteration Budget

- Explore 2-4 nodes per iteration (depending on complexity)
- After each node, update all files immediately
- When you feel context getting heavy, STOP, save, and exit

## Neighbor Loading Rules

ASK YOURSELF: "Do I need to know what's INSIDE this neighbor,
or just that a connection EXISTS?"

- Connection exists → just create the edge. Don't read the node.
- Need to understand the interface/contract → read ONLY the
  exports section from the neighbor's node file
- Need to understand data flow through the neighbor → read
  the full node file

Most of the time, you just need the first option.

## Exit Conditions

- Queue empty → <promise>MAP_COMPLETE</promise>
- Context filling up → save → <promise>CONTEXT_FULL</promise>
- Budget limit reached → save → <promise>BUDGET_REACHED</promise>
```

## The Loop Script (explore.sh)

```bash
#!/bin/bash
MAX_ITERATIONS="${1:-20}"
SEED="${2:-}"
SCOPE_FILE="exploration/scope.json"

# Pull budget from scope.json if it exists
if [ -f "$SCOPE_FILE" ]; then
    CONFIGURED_MAX=$(grep -o '"max_iterations": [0-9]*' "$SCOPE_FILE" | grep -o '[0-9]*')
    if [ -n "$CONFIGURED_MAX" ]; then
        MAX_ITERATIONS="$CONFIGURED_MAX"
    fi
fi

# Initialize on first run
if [ ! -f exploration/index.json ]; then
    mkdir -p exploration/nodes exploration/edges

    if [ -z "$SEED" ]; then
        echo "Usage: ./explore.sh [max_iterations] [seed_file]"
        echo "Example: ./explore.sh 30 src/services/billing.ts"
        exit 1
    fi

    echo '{}' > exploration/index.json

    cat > exploration/queue.json << EOF
{
  "pending": [
    {
      "node": "$SEED",
      "discovered_from": "seed",
      "reason": "starting point",
      "priority": "high",
      "depth": 0
    }
  ],
  "explored": [],
  "boundaries_recorded": 0,
  "externals_skipped": 0
}
EOF

    cat > exploration/stats.json << EOF
{
  "seed": "$SEED",
  "started": "$(date -I)",
  "total_nodes_discovered": 1,
  "total_nodes_explored": 0,
  "total_edges": 0,
  "last_iteration": 0,
  "coverage_pct": 0
}
EOF

    echo "# Exploration Findings" > exploration/findings.md
    echo "" >> exploration/findings.md
    echo "Seed: \`$SEED\`" >> exploration/findings.md
    echo "Started: $(date)" >> exploration/findings.md
    echo "" >> exploration/findings.md
fi

for i in $(seq 1 "$MAX_ITERATIONS"); do
    # Pre-check: is queue empty?
    if [ -f exploration/queue.json ]; then
        PENDING=$(grep -c '"node"' exploration/queue.json 2>/dev/null || echo "0")
        if [ "$PENDING" -eq 0 ]; then
            echo "Queue empty. Scope fully mapped."
            exit 0
        fi
        echo "=== Iteration $i / $MAX_ITERATIONS | $PENDING nodes pending ==="
    fi

    PROMPT=$(cat scripts/explore/PROMPT.md)

    claude -p "$PROMPT

Iteration $i. Save after EACH node — not in batches.
" 2>&1 | tee "/tmp/explore_$i.log"

    if grep -q "MAP_COMPLETE" "/tmp/explore_$i.log"; then
        echo "Exploration complete!"
        TOTAL_NODES=$(grep -c '"explored": true' exploration/index.json 2>/dev/null || echo "?")
        echo "Mapped $TOTAL_NODES nodes."
        exit 0
    fi

    if grep -q "BUDGET_REACHED" "/tmp/explore_$i.log"; then
        echo "Budget limit hit. Check exploration/findings.md for coverage."
        exit 0
    fi

    sleep 3
done

echo "Max iterations reached. Run again to continue from the queue."
```

## Usage

```bash
# Start from a specific file
./scripts/explore/explore.sh 30 packages/billing/src/services/payment.ts

# Start from an entry point
./scripts/explore/explore.sh 40 src/index.ts

# Continue a previous exploration (no seed needed, picks up from queue)
./scripts/explore/explore.sh 20

# Widen scope later: edit scope.json, add to queue, rerun
./scripts/explore/explore.sh 20
```

## Token Budget per Iteration

| What | Approximate tokens |
|------|-------------------|
| scope.json | ~500 |
| index.json (50 nodes) | ~2,000 |
| index.json (200 nodes) | ~8,000 |
| queue.json | ~500–1,000 |
| stats.json | ~100 |
| One neighbor node file | ~300–500 |
| Reading one source file | ~200–2,000 |
| grep results | ~200–500 per search |
| **Total overhead** | **~3,000–10,000** |
| **Remaining for actual work** | **~190,000+** |

Even at 200 discovered nodes, `index.json` stays manageable. The agent has nearly the full context window available for exploring source files and tracing connections.

## Expected Output

After running against a package in a large monorepo:

```
Stats:
  Tier 1 (fully explored):  43 nodes
  Tier 2 (boundary only):   12 nodes
  Tier 3 (skipped):         87 nodes
  Edges:                    156
  Iterations used:          14 of 20
  Coverage of billing pkg:  100%

Boundary dependencies:
  packages/auth       → verifyToken, AuthUser, requireRole
  packages/users      → getUserById, UserProfile
  packages/shared/db  → getConnection, transaction
  packages/shared/logger → logger.info, logger.error
```

The result is a machine-readable graph you can visualize (D3, Mermaid), query programmatically, or feed into a future Claude conversation as compressed context about your system.

## Widening Scope

To explore a different area, update `scope.json` with new seed and boundaries, clear the queue, and rerun. Previous boundary nodes from earlier runs even give you a head start — you already know which exports matter.
