# How to Build a Cartographer Test Run

The cartographer skip the pre-phase for testing — you manually create
the scope.json that the pre-phase would have produced, then run
`--init` and the main loop against a real codebase.

## Directory Layout

The script resolves `PROJECT_ROOT` as the parent of `cartographer/`.
Your test workspace needs this shape:

```
test_run/                          ← PROJECT_ROOT
├── cartographer/
│   ├── explore.sh                 ← copy from repo
│   ├── PROMPT.md                  ← copy from repo
│   ├── logs/
│   └── exploration/
│       └── scope.json             ← you create this
└── <codebase>/                    ← symlink or real checkout
    └── src/...
```

The codebase can be a symlink:

```bash
mkdir -p test_run/cartographer/exploration test_run/cartographer/logs
cp cartographer/explore.sh cartographer/PROMPT.md test_run/cartographer/
ln -s /path/to/real/repo test_run/<repo-name>
```

Paths in scope.json are relative to PROJECT_ROOT, so if the
symlink is `test_run/myrepo`, paths look like `myrepo/src/...`.

## Writing scope.json

The pre-phase normally produces this. For testing, write it by hand.
All five fields are required — `--init` validates their presence.

```json
{
  "seed": "myrepo/src/core/main.ts",
  "boundaries": {
    "explore_within": ["myrepo/src/core/**"],
    "boundary_packages": ["myrepo/src/utils", "myrepo/src/db"],
    "ignore": ["**/*.test.ts", "**/*.md"]
  },
  "budget": {
    "max_iterations": 5,
    "max_nodes": 20
  }
}
```

### How to choose each field

**seed** — any file in the slice. Not used by the script loop
(everything in explore_within gets queued), but documents intent.

**explore_within** — the directory glob(s) the agent will fully
describe. This is your slice. Use `**` suffix. Multiple globs OK:
`["myrepo/src/core/**", "myrepo/src/api/**"]`.

**boundary_packages** — sibling packages that the slice imports
from but you don't want to fully explore. The agent creates
minimal boundary nodes for these (just interface, no deep read).
Look at the import statements in your slice to find these.

**ignore** — file patterns to exclude from the queue. Only
`**/*.ext` patterns work (the discover function matches on file
extension). Patterns like `**/*_test.go` do NOT work due to a
known limitation — the glob-to-grep conversion only handles
extension-based patterns.

**budget** — `max_iterations` caps loop iterations, `max_nodes`
caps how many files get explored. Set both higher than the actual
file count to avoid early cutoff.

### Sizing the slice

Check file count before writing scope.json:

```bash
find myrepo/src/core -type f -name '*.ts' | grep -v test | wc -l
```

The script sends BATCH_SIZE=3 files per iteration. So:
- 9 files → 3 iterations
- 20 files → 7 iterations
- 50 files → 17 iterations

Each iteration is one full agent invocation (cold start, read
scope, explore files, write output). Budget time accordingly.

## Running

```bash
# 1. Initialize — creates queue_all.txt, queue_explored.txt, index.json
cd test_run
bash cartographer/explore.sh --init

# 2. Run with haiku (cheapest, fastest)
CLAUDE_MODEL=claude-haiku-4-5-20251001 bash cartographer/explore.sh

# Or limit iterations explicitly:
CLAUDE_MODEL=claude-haiku-4-5-20251001 bash cartographer/explore.sh 5

# Or use a different provider:
bash cartographer/explore.sh codex 5
```

## What --init produces

```
exploration/
├── scope.json          ← unchanged (your input)
├── queue_all.txt       ← one file path per line, all in-scope files
├── queue_explored.txt  ← empty (nothing explored yet)
├── index.json          ← {} (empty)
├── findings.md         ← header only
├── nodes/              ← empty dir
└── edges/              ← empty dir
```

## What the loop produces

After each iteration, the script checks which files in the batch
got a node file written by the agent. Only those are appended to
queue_explored.txt. If the agent fails or skips a file, it stays
in the queue for next iteration.

```
exploration/
├── queue_explored.txt                          ← grows each iteration
├── index.json                                  ← agent updates this
├── nodes/
│   ├── myrepo__src__core__main.ts.json         ← node description
│   └── myrepo__src__core__router.ts.json
└── edges/
    ├── myrepo__src__core__main.ts.edges.json   ← dependency edges
    └── myrepo__src__core__router.ts.edges.json
```

## Inspecting results

```bash
# How many files done?
wc -l < exploration/queue_all.txt      # total
wc -l < exploration/queue_explored.txt # explored

# What's still pending?
comm -23 <(sort exploration/queue_all.txt) <(sort exploration/queue_explored.txt)

# Read a node:
cat exploration/nodes/myrepo__src__core__main.ts.json | python3 -m json.tool

# Check index completeness:
python3 -c "
import json
idx = json.load(open('exploration/index.json'))
print(f'{len(idx)} entries')
for k,v in idx.items():
    print(f\"  {'✓' if v.get('explored') else '○'} {k}\")
"
```

## Cleanup

```bash
rm -rf test_run
```

## Example: tg-digest/internal/summarizer

Slice: 5 source files + 4 test files = 9 files total.

Boundary packages: storage, config, source, refresh, tui, telegram, cmd.
These are sibling packages under `tg-digest/internal/` that the
summarizer imports from.

```json
{
  "seed": "tg-digest/internal/summarizer/summarizer.go",
  "boundaries": {
    "explore_within": ["tg-digest/internal/summarizer/**"],
    "boundary_packages": [
      "tg-digest/internal/storage",
      "tg-digest/internal/config",
      "tg-digest/internal/source",
      "tg-digest/internal/refresh",
      "tg-digest/internal/tui",
      "tg-digest/internal/telegram",
      "tg-digest/cmd"
    ],
    "ignore": ["**/*.md"]
  },
  "budget": {
    "max_iterations": 5,
    "max_nodes": 10
  }
}
```

Result: 3 iterations, 9/9 files explored, all with node + edge
output. Haiku completed it in ~4 minutes total.
