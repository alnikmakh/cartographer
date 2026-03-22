# Cartographer v2 — Monorepo / Turborepo Guide

How to run cartographer against individual packages in a monorepo
(Turborepo, Nx, Lerna, Rush, or any `packages/` structure).

## Overview

Cartographer maps one package at a time. For a monorepo, you either:
1. **Run per-package** — map each package independently
2. **Run cross-package** — map multiple packages, then cross-scope synthesis finds the connections

Both approaches use the same pipeline. The key is setting paths correctly.

## Quick Start: Single Package

```bash
MONOREPO=/path/to/your/monorepo
PACKAGE=packages/api-server

# 1. Index the package
cgc index "$MONOREPO/$PACKAGE"

# 2. Create scope
mkdir -p cartographer/exploration
cat > cartographer/exploration/scope.json << EOF
{
  "seed": "$PACKAGE/src/index.ts",
  "boundaries": {
    "explore_within": ["$PACKAGE/src/**"],
    "boundary_packages": []
  },
  "hints": []
}
EOF

# 3. Run exploration + synthesis
PROJECT_ROOT="$MONOREPO" ./cartographer/explore.sh --init
PROJECT_ROOT="$MONOREPO" ./cartographer/explore.sh
./cartographer/synthesize.sh "$MONOREPO"
```

Output: `cartographer/exploration/findings.md`

## Full Monorepo: Multiple Packages

### Option A: Automatic scope detection

Let the prephase (Opus + CGC) determine scopes automatically:

```bash
MONOREPO=/path/to/your/monorepo

# Index the entire monorepo (or specific packages)
cgc index "$MONOREPO"

# Run full pipeline — prephase discovers scopes
./cartographer/run.sh "$MONOREPO"
```

The prephase queries the dependency graph and identifies natural scopes
based on import clusters. For a typical turborepo it will usually create
one scope per package.

### Option B: One scope per package (manual)

Write scope.json files yourself — useful when you know the package
boundaries and want control:

```bash
MONOREPO=/path/to/your/monorepo

# Create a scope directory per package
for pkg in api-server web-client shared-utils; do
    mkdir -p cartographer/prephase/scopes/$pkg
    cat > cartographer/prephase/scopes/$pkg/scope.json << EOF
{
  "seed": "packages/$pkg/src/index.ts",
  "boundaries": {
    "explore_within": ["packages/$pkg/src/**"],
    "boundary_packages": []
  },
  "hints": []
}
EOF
done

# Run with SKIP_PREPHASE since we wrote scopes manually
SKIP_PREPHASE=1 ./cartographer/run.sh "$MONOREPO"
```

### Option C: Script it for Turborepo

Auto-detect packages from `turbo.json` or the directory structure:

```bash
#!/bin/bash
MONOREPO=/path/to/your/monorepo

# Index once
cgc index "$MONOREPO"

# Create scopes from packages/*/
for pkg_dir in "$MONOREPO"/packages/*/; do
    pkg=$(basename "$pkg_dir")

    # Skip packages with no source
    [ -d "$pkg_dir/src" ] || continue

    mkdir -p cartographer/prephase/scopes/$pkg

    # Detect entry point
    SEED=""
    for candidate in src/index.ts src/index.tsx src/main.ts src/app.ts; do
        if [ -f "$pkg_dir/$candidate" ]; then
            SEED="packages/$pkg/$candidate"
            break
        fi
    done
    [ -z "$SEED" ] && SEED="packages/$pkg/src/$(ls "$pkg_dir/src/" | head -1)"

    # Detect internal dependencies (other packages this one imports)
    BOUNDARIES=""
    if [ -f "$pkg_dir/package.json" ]; then
        # Find workspace deps (packages starting with @yourorg/)
        BOUNDARIES=$(python3 -c "
import json
with open('$pkg_dir/package.json') as f:
    pkg_json = json.load(f)
deps = {**pkg_json.get('dependencies', {}), **pkg_json.get('devDependencies', {})}
workspace_deps = [d for d in deps if d.startswith('@')]
# Map @org/pkg-name to packages/pkg-name (adjust for your structure)
for d in workspace_deps:
    name = d.split('/')[-1]
    print(f'\"packages/{name}/src\"', end=', ')
" 2>/dev/null)
    fi

    cat > cartographer/prephase/scopes/$pkg/scope.json << EOF
{
  "seed": "$SEED",
  "boundaries": {
    "explore_within": ["packages/$pkg/src/**"],
    "boundary_packages": [${BOUNDARIES%,}]
  },
  "hints": []
}
EOF

    echo "Created scope: $pkg (seed: $SEED)"
done

# Run pipeline (parallel exploration + synthesis, cross-scope at end)
SKIP_PREPHASE=1 ./cartographer/run.sh "$MONOREPO"
```

## Path Conventions

Cartographer paths are **relative to PROJECT_ROOT** (or the source root
argument). In a monorepo:

| Setting | Value | Example |
|---------|-------|---------|
| `PROJECT_ROOT` | monorepo root | `/home/dev/my-monorepo` |
| `SOURCE_ROOT` | same as PROJECT_ROOT (for git) | `/home/dev/my-monorepo` |
| `seed` in scope.json | relative path from root | `packages/api/src/index.ts` |
| `explore_within` | relative glob from root | `packages/api/src/**` |
| `boundary_packages` | relative paths from root | `packages/shared/src` |

## Cross-Package Dependencies

When packages import from each other, use `boundary_packages` to declare
the dependency:

```json
{
  "seed": "packages/api-server/src/index.ts",
  "boundaries": {
    "explore_within": ["packages/api-server/src/**"],
    "boundary_packages": [
      "packages/shared-utils/src",
      "packages/database/src"
    ]
  }
}
```

The explorer records boundary edges to these packages (coupling type,
data flow) without fully exploring them. When you map `shared-utils`
as its own scope, the cross-scope synthesis connects the dots.

## Cross-Scope Synthesis

After all packages are explored and synthesized, the cross-scope step
(Opus) reads all scope-manifest.json files and produces `architecture.md`:

- How packages depend on each other
- Types that cross package boundaries
- Contract mismatches between producer and consumer
- Inconsistent patterns across packages
- Architectural assessment

This is the highest-value step for monorepos — it finds issues that
live at package boundaries.

## Turborepo-Specific Tips

### apps/ vs packages/

Turborepo conventionally separates `apps/` (deployable) from `packages/`
(shared libraries). Map them the same way — just adjust the glob:

```json
{
  "explore_within": ["apps/web/src/**"],
  "boundary_packages": ["packages/ui/src", "packages/config/src"]
}
```

### Ignoring generated code

If `turbo` generates code (e.g., GraphQL codegen, Prisma client),
exclude those directories from `explore_within`:

```json
{
  "explore_within": [
    "packages/api/src/**"
  ]
}
```

Then don't include generated directories. The agent explores everything
under the glob, so keep globs tight to source directories.

### Large packages

For packages with 100+ source files, the prephase (Option A) may split
them into multiple scopes automatically. This is usually the right call —
let Opus decide where the natural boundaries are.

### Incremental after turbo build

After a `turbo build` or `turbo dev` cycle that modifies source:

```bash
./cartographer/run.sh "$MONOREPO" --incremental
```

This detects changed files via `git diff`, re-explores only affected
scopes, re-synthesizes if manifests changed, and re-runs cross-scope
if needed.

## Example: Turborepo with 3 packages

```
my-monorepo/
├── turbo.json
├── packages/
│   ├── api/
│   │   ├── package.json
│   │   └── src/
│   │       ├── index.ts
│   │       ├── routes/
│   │       └── middleware/
│   ├── web/
│   │   ├── package.json
│   │   └── src/
│   │       ├── App.tsx
│   │       ├── pages/
│   │       └── components/
│   └── shared/
│       ├── package.json
│       └── src/
│           ├── types.ts
│           └── utils.ts
```

```bash
# Index once
cgc index /path/to/my-monorepo

# Create scopes
for pkg in api web shared; do
    mkdir -p cartographer/prephase/scopes/$pkg
done

cat > cartographer/prephase/scopes/shared/scope.json << 'EOF'
{
  "seed": "packages/shared/src/types.ts",
  "boundaries": {
    "explore_within": ["packages/shared/src/**"],
    "boundary_packages": []
  }
}
EOF

cat > cartographer/prephase/scopes/api/scope.json << 'EOF'
{
  "seed": "packages/api/src/index.ts",
  "boundaries": {
    "explore_within": ["packages/api/src/**"],
    "boundary_packages": ["packages/shared/src"]
  }
}
EOF

cat > cartographer/prephase/scopes/web/scope.json << 'EOF'
{
  "seed": "packages/web/src/App.tsx",
  "boundaries": {
    "explore_within": ["packages/web/src/**"],
    "boundary_packages": ["packages/shared/src"]
  }
}
EOF

# Run: shared first (foundation), then api+web (parallel), then cross-scope
SKIP_PREPHASE=1 ./cartographer/run.sh /path/to/my-monorepo
```

Output:
- `runs/shared/cartographer/exploration/findings.md` — shared library docs
- `runs/api/cartographer/exploration/findings.md` — API server docs
- `runs/web/cartographer/exploration/findings.md` — web app docs
- `runs/architecture.md` — how they all connect, contract mismatches, shared type lineage
