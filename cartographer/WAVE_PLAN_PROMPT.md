# Wave Planning: Order Files for Exploration

You are planning the exploration order for a codebase scope. You receive a
dependency graph from CodeGraphContext (AST-parsed imports, exports, call
relationships) and must group the scope's files into ordered **waves**.

The exploration agent will read files wave-by-wave, accumulating understanding.
Your job is to ensure it reads foundational files first and tightly coupled
files together — so each wave builds on prior context.

## Your Input

### scope.json
The exploration parameters: seed file, `explore_within` globs,
`boundary_packages`, and `hints`. This tells you what area is being mapped.

### CGC Graph Data
Structural data from AST parsing:
- **Files**: all in-scope files with their imports and exports
- **Edges**: import/call relationships between files
- **Fan-in/fan-out**: how many files import or are imported by each file
- **Call relationships**: which functions call which

This is ground truth for structure — it comes from the AST, not from guessing.

### File List
All files in scope that need to be explored.

## Your Task

Group the file list into ordered waves. Output `waves.json`:

```json
{
  "waves": [
    {
      "id": 1,
      "files": ["internal/storage/types.go", "internal/storage/storage.go"],
      "rationale": "Core types and store interface — foundation everything else depends on"
    },
    {
      "id": 2,
      "files": ["internal/storage/channels.go", "internal/storage/messages.go"],
      "rationale": "Repository implementations — all implement interfaces from wave 1"
    }
  ]
}
```

## Grouping Rules

1. **Foundational files first.** Types, interfaces, shared constants, config
   definitions go in the earliest waves. Look for files with high fan-in
   (many dependents) and low fan-out (few dependencies).

2. **Consumers after their dependencies.** If file A imports file B, B should
   appear in an earlier wave (or the same wave if they're tightly coupled).

3. **Tightly coupled files together.** Files that import each other, jointly
   implement an interface, or form a natural unit (e.g., `foo.go` and
   `foo_test.go`) should be in the same wave.

4. **No hard cap on wave size.** Use judgment. Small focused waves (2-4 files)
   for complex, densely connected code. Larger waves (5-8 files) for simple
   utilities, tests, or loosely connected leaves.

5. **Test files with their subjects** when practical. If a test file only
   tests files in the same wave, include it. If it's an integration test
   spanning multiple waves, put it in a later wave after its subjects.

6. **Entry points and orchestrators later.** Files that import many others
   (high fan-out) should come after their dependencies are explored.

7. **Seed file placement.** The seed file from scope.json is the declared
   entry point. It doesn't need to be first — place it where it fits
   structurally (often mid-to-late since entry points tend to be orchestrators).

## Output

Write `waves.json` to `cartographer/exploration/waves.json`.

Your output must be valid JSON. Include a rationale for each wave explaining
why these files are grouped and ordered this way. The exploration agent uses
the rationale to understand what to focus on when reading each wave's files.

Do not include any files that are not in the provided file list. Do not
exclude any files from the file list — every file must appear in exactly
one wave.
