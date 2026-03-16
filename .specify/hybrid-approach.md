# Cartographer Hybrid Approach

Incremental integration of modern agentic tools into cartographer's pipeline.
Each phase is independent and delivers value on its own — later phases do not
require earlier ones to ship first.

```
Current:  repomix → structure.xml → prephase AI → scope.json → bash loop → agent → nodes/edges → synthesis
      OR: CGC graph ──────────→ prephase AI → scope.json → bash loop → agent → nodes/edges → synthesis
          (Phase 1 ✅)                                       ↑ pre-populated     (Phase 3)
                                                             │ edges (Phase 2)
                                                             │
                                                       LangGraph orchestration (Phase 4)
```

---

## Phase 1 — CodeGraphContext for Pre-Phase Input ✅ IMPLEMENTED

**Replaces:** `extract.sh` / repomix → `structure.xml`

**Status:** Implemented and tested. See `cartographer/prephase/cgc/`.

**What was built:**

1. `cgc/setup.sh` — indexes target repo with `cgc index <path>`. Uses KuzuDB
   (embedded, zero-config) as the graph backend. Install: `pip install
   codegraphcontext kuzu`.
2. `cgc/mcp.json` — MCP server config for `claude -p --mcp-config`. Command:
   `cgc mcp start`. Exposes 18 tools including `find_code`,
   `analyze_code_relationships`, `execute_cypher_query`.
3. `cgc/PROMPT.md` / `cgc/AUTO_PROMPT.md` — graph-native prephase prompts.
   Same structure as repomix prompts but query the graph via MCP instead of
   reading XML. Graph-native cluster detection: query entry points, fan-in
   hubs, connected components, bridge files.
4. `cgc/auto.sh` — runs AUTO_PROMPT.md with `--mcp-config`.
5. Operator chooses approach: repomix OR CGC. No mixing, no fallback logic.

**Output contract:** `scope.json` with seed, boundaries (explore_within +
boundary_packages), and hints. No `ignore`, no `budget` — both removed from
the schema after testing showed they caused more problems than they solved.

**Test results (tg-digest, 53 Go files):**
- CGC prephase produced 7 slices covering all packages
- 7 parallel Haiku cartographers: 57/57 files explored, 59 nodes, 59 edges
- Budget removal was key: with budget, 50/57 explored (88%); without, 57/57 (100%)

**Known issues:**
- CGC graph prefixes paths with repo name (e.g., `tg-digest/internal/...`).
  Must strip prefix when scopes target directory structures without that level.
- `claude -p` resolves relative paths from git project root, not shell cwd.
  Parallel instances need absolute paths in PROMPT.md.

**Language support:** Python, TypeScript, JavaScript, Java, Go, Rust, C/C++,
C#, Ruby, PHP, Swift, Kotlin, Dart, Perl (14 languages via tree-sitter).

---

## Phase 2 — Pre-Populated Dependency Edges

**Augments:** The exploration phase (`explore.sh` loop)

**Problem today:** The explore agent reads each file batch, discovers what it
calls/imports, and writes edge JSON. This is the most expensive part of each
iteration — the agent spends tokens on mechanical dependency tracing that an AST
parser does deterministically in milliseconds.

**What changes:**

1. After `--init` globs files into `queue_all.txt`, query CGC's graph (via MCP
   or CLI) for all queued files.
2. For each file, emit a `pre_edges.json` containing tree-sitter-derived
   relationships:
   - imports / requires
   - function calls (resolved to target file:line where possible)
   - class inheritance
   - module re-exports
3. Feed `pre_edges.json` into the agent prompt as pre-verified context. The
   agent prompt gains a section:
   ```
   ## Pre-Verified Edges
   The following dependency edges were extracted via AST analysis and are
   confirmed accurate. You do not need to re-discover these. Focus your
   analysis on:
   - Describing WHAT each file/function does (semantic understanding)
   - Classifying files as in-scope / boundary / external
   - Adding notes and hints that enrich the mechanical graph
   - Identifying relationships the AST cannot capture (runtime dispatch,
     config-driven wiring, convention-based coupling)
   ```
4. The agent still writes final `edges/` JSON but starts from a populated
   baseline rather than a blank slate.

**Expected gains:**
- Fewer tokens per iteration (agent skips import/call tracing).
- Higher edge accuracy (AST extraction is deterministic).
- Agent attention shifts from mechanical discovery to semantic interpretation —
  the part no parser can do.

**Key risks:**
- Tree-sitter extraction is syntactic — it may miss edges from dynamic imports
  or metaprogramming. Mitigation: mark AST edges with a `confidence` field;
  agent can override and add edges the parser missed.
- Pre-edges may bloat prompt context for large files. Mitigation: summarize
  pre-edges per file (count + top-5 by fan-out), full list available via tool
  call.

---

## Phase 3 — Post-Synthesis with LlamaIndex KG-RAG

**Augments:** Synthesis phase output

**Problem today:** Synthesis produces a static `findings.md` document. To answer
a new question about the codebase, you either re-read the document or re-run
exploration.

**What changes:**

1. After synthesis completes, ingest all exploration output (`nodes/`, `edges/`,
   `index.json`, `findings.md`) into a LlamaIndex KnowledgeGraphIndex.
2. Nodes become graph entities with their descriptions as properties. Edges
   become typed relationships. Findings become associated text chunks.
3. Expose the index via a KnowledgeGraphRAGQueryEngine that supports:
   - Natural language questions ("How does auth middleware connect to the session
     store?")
   - Graph traversal ("Show all files within 2 hops of `router.ts`")
   - Hybrid retrieval (vector similarity on descriptions + graph structure on
     edges)
4. Optionally persist the index to disk so it survives across sessions. Re-index
   incrementally when exploration reruns on new slices.

**Integration surface:**

```python
from llama_index.core import KnowledgeGraphIndex, StorageContext
from llama_index.graph_stores.neo4j import Neo4jGraphStore  # or FalkorDB

# Ingest cartographer output
graph_store = Neo4jGraphStore(...)
storage_context = StorageContext.from_defaults(graph_store=graph_store)
index = KnowledgeGraphIndex.from_documents(
    cartographer_documents,  # parsed from nodes/ + edges/ + findings.md
    storage_context=storage_context,
)
query_engine = index.as_query_engine(include_text=True, response_mode="tree_summarize")
```

**Key risks:**
- LlamaIndex's KG indexing may lose nuance from cartographer's rich node
  descriptions. Mitigation: preserve full description text as node properties,
  not just entity names.
- Graph store adds operational weight. Mitigation: use LlamaIndex's built-in
  SimpleGraphStore for lightweight/local use; upgrade to Neo4j only for large
  explorations.

---

## Phase 4 — LangGraph Orchestration

**Replaces:** `explore.sh` bash loop and manual phase transitions

**Problem today:** The pipeline is a bash script with `while` loops, file-based
state (`queue_all.txt`, `queue_done.txt`), and no crash recovery. If the agent
fails mid-exploration, you restart from the beginning or manually patch queue
files.

**What changes:**

1. Model the full pipeline as a LangGraph StateGraph:

   ```
   ┌─────────┐    ┌──────────┐    ┌─────────┐    ┌───────────┐    ┌───────────┐
   │  CGC     │───→│ prephase │───→│  init   │───→│  explore  │───→│ synthesis │
   │ extract  │    │ (scope)  │    │ (queue) │    │  (loop)   │    │ (KG-RAG)  │
   └─────────┘    └──────────┘    └─────────┘    └───────────┘    └───────────┘
                       │                              │  ↺
                       │ human-in-the-loop            │ batch loop
                       │ (approve slices)             │ with checkpoint
   ```

2. State schema (TypedDict):
   ```python
   class CartographerState(TypedDict):
       repo_path: str
       cgc_graph: str              # Neo4j graph DB URI (CodeGraphContext)
       scope: dict                 # scope.json content
       queue_all: list[str]        # all files to explore
       queue_done: list[str]       # explored files
       queue_current: list[str]    # current batch
       nodes: dict                 # accumulated node JSON
       edges: dict                 # accumulated edge JSON
       pre_edges: dict             # AST-derived edges (Phase 2)
       findings: str               # synthesis output
       kg_index: str               # LlamaIndex index path (Phase 3)
   ```

3. Each node is a Python function that reads/writes state. The explore node
   uses a conditional edge to loop back to itself until `queue_all` is
   exhausted.

4. LangGraph checkpointing persists state after every node execution. A
   crashed run resumes from the last completed batch — no manual queue
   patching.

5. The prephase node uses LangGraph's `interrupt()` for human-in-the-loop
   slice approval (interactive mode) or runs straight through (auto mode).

**Expected gains:**
- Crash recovery via built-in checkpointing.
- Observability — LangGraph Studio visualizes the graph execution in real time.
- Cleaner state management — typed dict vs scattered files.
- Easier to add new phases (e.g., incremental re-exploration of changed files).

**Key risks:**
- LangGraph is Python-only. Current pipeline is bash + any-provider CLI. Moving
  to LangGraph couples the orchestration to Python. Mitigation: keep provider
  calls as subprocess invocations within LangGraph nodes — the graph manages
  state, the agent calls remain CLI-based.
- Over-engineering risk. The bash loop works. Mitigation: only move to LangGraph
  when the pipeline needs features bash can't provide (checkpointing, parallel
  batches, dynamic re-planning).
- Vendor dependency on LangChain ecosystem. Mitigation: LangGraph is OSS
  (MIT-licensed) and the state/node pattern is portable — migration cost to
  another framework is moderate.

---

## Sequencing

| Phase | Effort | Prerequisite | Biggest win | Status |
|-------|--------|--------------|-------------|--------|
| 1     | Medium | CGC + KuzuDB | Smarter scoping from queryable structure | ✅ Done |
| 2     | Low    | Phase 1 (reuses CGC graph) | Cheaper, faster, more accurate exploration | |
| 3     | Medium | None (works with current output) | Exploration results become interactive | |
| 4     | High   | None (but benefits from 1-3) | Crash recovery, observability, cleaner state | |

Phase 1 is complete. Backend is KuzuDB (embedded), not Neo4j — no Docker needed.
Phase 2 can now reuse the CGC graph indexed for Phase 1.
Phase 3 can ship independently at any time — it only consumes existing output.
Phase 4 is the largest change and should come last.
