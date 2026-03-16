# Cartographer Agent: Writes to Wrong Path + Hallucinated Writes

## Observed: 2026-03-16

## What Happened

Running 6 cartographer explorations in parallel against tg-digest slices. Each agent ran in an isolated directory tree with symlinked source files. Results appeared mixed: 4/6 "worked", 2/6 produced zero output despite correct analysis.

**Root cause discovered:** ALL 6 agents wrote to `/home/dev/project/cartographer/exploration/` (the global path from the git root), not to their isolated `runs/<slug>/cartographer/exploration/` directories.

`claude -p` resolves relative paths from the **git project root**, not from the shell's `cwd`. The PROMPT.md contains `cartographer/exploration/nodes/...` which always resolves to the same global directory regardless of where the shell launched the process.

The 4 "successful" runs were cross-contaminated — explore.sh's node-existence check found files written by OTHER agents to the shared global path. The 2 "failed" runs simply had their files overwritten or were checking for files that ended up with different sanitized names.

## The actual failure mode

1. Agent receives relative path `cartographer/exploration/nodes/...` in prompt
2. Agent resolves it from git project root → `/home/dev/project/cartographer/exploration/nodes/...`
3. Agent writes there (not to the isolated run directory)
4. explore.sh checks for nodes in `$SCRIPT_DIR/exploration/nodes/` (the isolated dir)
5. Node not found → "0 files explored"
6. On retry, agent reads the global index.json (which now has entries from other runs) and sees "already explored"

This explains both the "hallucinated writes" AND why 4/6 appeared to succeed — they were reading each other's output from the shared global path.

## Fix

**Use absolute paths in PROMPT.md when running isolated instances.**

When generating per-slug PROMPT.md files, sed-replace all `cartographer/exploration/` references with the absolute path to that slug's exploration directory. This makes the agent write to the correct location regardless of how `claude -p` resolves relative paths.

```bash
sed "s|cartographer/exploration/|$ABSOLUTE_EXPLORATION_PATH/|g" PROMPT.md > runs/$slug/cartographer/PROMPT.md
```

## Broader implication for explore.sh

The default explore.sh works fine when run from the standard location because `cartographer/exploration/` relative to the git root IS the correct path. This only breaks when you try to run multiple isolated instances.

If explore.sh ever needs to support relocatable exploration directories, the PROMPT.md should be templated with `{{EXPLORATION_DIR}}` and the script should substitute at runtime. For now, the sed approach in run-all.sh is sufficient.
