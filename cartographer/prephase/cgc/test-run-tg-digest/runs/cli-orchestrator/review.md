# Review: cli-orchestrator findings.md

Reviewer verified every claim against actual source code in `/home/dev/project/tg-digest/`.

## Scores

- **Accuracy score**: 9/10
- **Completeness score**: 8/10
- **Usefulness score**: 9/10

## Inaccuracies Found

### 1. HackerNews `feed` default in main.go is dead code (Minor)

**Doc says** (Non-Obvious Behaviors, bullet 5): "HackerNews defaults `feed="top"` and `limit=30` in main (`main.go:80-88`), not in config."

**What the code actually does**: `config.go:166-168` validates that `feed` is required for hackernews sources and returns an error if empty. The `feed == ""` branch in `main.go:80-82` can therefore never execute -- it is dead code. Only the `limit` default (main.go:84-86) actually takes effect at runtime.

The doc presents this as a design pattern ("defaults happen in main, not config") but for `feed` the real behavior is "config rejects missing feed." The Reddit `sort` default in main.go IS correct since config does not validate sort.

### 2. OpenRouter timeout config value is silently unused (Omission rather than inaccuracy)

**Doc says** (Non-Obvious Behaviors, bullet 2): "Ollama gets 120s, OpenRouter gets 30s" as timeout defaults.

**What the code actually does**: `buildLLMClient` at main.go:327 calls `summarizer.NewOpenRouterClient(cfg.OpenRouterAPIKey, cfg.OpenRouterBase)` -- it never passes `TimeoutSeconds` to the OpenRouter client constructor, unlike the Ollama path which does pass timeout (main.go:317). The 30s default is set in config but never wired through. The doc describes the config defaults accurately but does not flag that the OpenRouter timeout is dead config.

### 3. No other inaccuracies

Every other claim in the document checks out against source code:
- All function signatures match exactly.
- All line number references are correct (verified ~25 references).
- The Config struct fields match `config.go:12-19`.
- The backward-compat migration logic at `config.go:84-92` works as described.
- The adapter types at `main.go:275-312` match the documented signatures and behaviors.
- The `ensureSourceChannel` error swallowing at `main.go:336-354` is accurate.
- The one-at-a-time message storage loop at `main.go:236-249` is accurate.
- The sync checkpoint as string via `strconv.Itoa` at `main.go:267` is accurate.
- The refresh interval defaulting behavior at `config.go:111-113` is accurate.
- Test coverage claims verified: ~24 config test functions and 5 buildLLMClient tests.
- `config_test.go:394-396` documenting empty Sort is accurate.

## Missing Important Details

1. **`CreateNonTelegram` vs `Create` for channel storage**: `ensureSourceChannel` (main.go:351) uses `store.Channels().CreateNonTelegram()` while `storeChannel` (main.go:227) uses `store.Channels().Create()`. This distinction implies the storage layer has separate insert paths for telegram vs non-telegram channels -- relevant for anyone modifying the persistence layer.

2. **Reddit hardcoded limit of 25**: `main.go:78` passes a hardcoded `25` to `NewRedditSource`. Unlike HackerNews which reads `sc.Limit` from config, Reddit's item limit is not configurable. This asymmetry is worth flagging.

3. **Signal handling**: `main()` creates a context with `signal.NotifyContext` for `os.Interrupt` (main.go:46-47). Relevant for understanding graceful shutdown.

4. **The `--debug` flag**: Passed to `telegram.FetchMessages` (main.go:146) but not mentioned in the data flow descriptions.

5. **`tea.WithAltScreen()` option**: The TUI is launched with alt screen mode (main.go:117), meaning it takes over the terminal. Relevant for understanding user experience.

6. **`SummarizeFiltered` method rename**: The adapter's `SummarizeFiltered` (main.go:310) delegates to `svc.SummarizeUnsummarizedForChannels` -- a name mismatch between the interface contract and the underlying service method. A developer debugging through the adapter would want to know this.

## Previous Review Comparison

A previous review existed at this path with scores 7/7/8 and listed inaccuracies including "eight exported functions" and "silently upgrades old files." Those claims do not appear in the current findings.md, suggesting the document was revised. The current version is substantially more accurate.

## Overall Assessment

This is a high-quality architectural document. Nearly every line number reference, function signature, and behavioral claim checks out against the actual source code -- I verified over 25 line references and found zero incorrect ones. The dependency diagram, data flow descriptions, and non-obvious behaviors section would genuinely accelerate a new developer's understanding of the codebase. The one substantive inaccuracy (HN feed default being dead code) is subtle but would mislead someone trying to understand where defaults are enforced. The missing details are real but secondary -- the document correctly prioritized the most architecturally significant information.
