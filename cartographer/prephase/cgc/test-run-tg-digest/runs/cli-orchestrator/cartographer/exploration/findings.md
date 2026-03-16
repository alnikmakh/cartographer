---
scope: cmd/digest/main.go
files_explored: 4
boundary_packages: 6
generated: TIMESTAMP
---

## Purpose

tg-digest's entry point wires together a multi-source content aggregation pipeline. It loads configuration, opens a database, constructs source-specific fetchers (Telegram, RSS, Reddit, HackerNews), and exposes them through either a one-shot CLI fetch-and-print mode or an interactive TUI with background refresh and LLM-powered summarization. Callers interact with it as an end-user binary — there is no library API.

## Architecture

**Dependency diagram**

```
                     config.Load()
                         │
                         ▼
                    ┌─────────┐
                    │ main.go │  ← orchestrator, no inbound deps
                    └────┬────┘
                         │
        ┌────────┬───────┼────────┬──────────┬──────────┐
        ▼        ▼       ▼        ▼          ▼          ▼
  [telegram]†  [storage]† [refresh]† [summarizer]†  [tui]†
                                      ▲                ▲
                                      │                │
                              summarizeService    registryRefresh
                              Adapter             Adapter
                                      │                │
                                      └──── [source]† ─┘
                                             ▲
                              ┌──────┬───────┼──────────┐
                              ▼      ▼       ▼          ▼
                          [source/   [source/ [source/   [source/
                          telegram]† rss]†    reddit]†   hackernews]†

  † boundary package
```

**Key interfaces and signatures**

From `internal/config/config.go`:
```go
func Load(path string) (*Config, error)

type Config struct {
    Telegram   TelegramConfig
    Storage    StorageConfig
    OpenRouter OpenRouterConfig  // legacy, migrated to LLM
    Refresh    RefreshConfig
    LLM        LLMConfig
    Sources    []SourceConfig
}
```

From `cmd/digest/main.go`:
```go
func buildLLMClient(ctx context.Context, cfg config.LLMConfig) (summarizer.Client, bool, error)
// Returns: (client, isLocal, error). isLocal=true for Ollama.

func storeChannel(ctx context.Context, store storage.Store, ch *tg.InputChannel, username string) (*storage.Channel, error)
func storeMessages(ctx context.Context, store storage.Store, channelID int64, messages []telegram.Message) error
func updateSyncState(ctx context.Context, store storage.Store, channelID int64, messages []telegram.Message) error
func ensureSourceChannel(ctx context.Context, store storage.Store, sc config.SourceConfig)
```

Adapter types bridging boundary packages to TUI interfaces:
```go
type registryRefreshAdapter struct { svc *refresh.Service; registry *source.Registry }
  func (a *registryRefreshAdapter) RefreshAll(ctx context.Context) (*refresh.RefreshResult, error)
  func (a *registryRefreshAdapter) RefreshFiltered(ctx context.Context, sourceNames []string) (*refresh.RefreshResult, error)

type summarizeServiceAdapter struct { svc *summarizer.Service }
  func (a *summarizeServiceAdapter) SummarizeUnsummarized(ctx context.Context) (*summarizer.SummarizeQueueResult, error)
  func (a *summarizeServiceAdapter) SummarizeFiltered(ctx context.Context, channelIDs []int64) (*summarizer.SummarizeQueueResult, error)
```

**Patterns**

- **Adapter** — `registryRefreshAdapter` and `summarizeServiceAdapter` bridge concrete service types to the TUI's interface contracts. This decouples the TUI from knowing about the source registry or summarizer internals.
- **Registry** — `source.Registry` collects heterogeneous source implementations behind a common `source.Source` interface, built up from config at startup.
- **Facade/Orchestrator** — `main.go` is a pure wiring file. It owns no domain logic; every operation delegates to a boundary package.

## Data Flow

**Flow 1: TUI mode startup**

1. `main()` parses CLI flags; `--tui` is set → enters TUI branch (line 56)
2. `config.Load(*configPath)` reads YAML, applies defaults, runs backward-compat migration, validates (line 41)
3. `storage.Open(ctx, cfg.Storage.DBPath)` opens the database (line 50)
4. `telegram.NewClient()` + `client.Run()` establishes Telegram session (lines 57-60)
5. Inside the Run callback: builds `source.Registry` by iterating `cfg.Sources`, constructing type-specific sources (lines 66-89)
6. For each source, `ensureSourceChannel()` creates a DB channel record if missing (line 91)
7. If registry has entries, wraps `refresh.Service` in `registryRefreshAdapter`; otherwise uses `refresh.Service` directly (lines 93-98)
8. `buildLLMClient()` → returns `(summarizer.Client, isLocal, error)` based on provider (line 104)
9. If LLM client exists, creates `summarizer.Service` and wraps in `summarizeServiceAdapter` (lines 108-115)
10. `tui.NewApp(store, opts...)` → `tea.NewProgram(app).Run()` launches interactive TUI (lines 116-120)

**Flow 2: CLI fetch mode**

1. `main()` parses flags; `--channel @durov --limit 20` (no `--tui`)
2. Config load + DB open + Telegram client setup (same as above)
3. `telegram.ResolveChannel(ctx, client.API(), *channel)` resolves username to `*tg.InputChannel` (line 135)
4. `storeChannel()` checks DB for existing channel by TelegramID, creates if missing (line 141)
5. `telegram.FetchMessages(ctx, client.API(), ch, *limit, *debug)` fetches from Telegram API (line 146)
6. `storeMessages()` iterates messages, calls `store.Messages().Create()` for each (line 157)
7. `updateSyncState()` finds max message ID, calls `store.SyncState().Upsert()` with checkpoint (line 162)
8. If `--summarize N` > 0: builds LLM client, creates `summarizer.Service`, calls `svc.SummarizeUnsummarized(ctx)` (lines 173-197)

## Boundaries

| Boundary | Role | Used By | Key Types |
|----------|------|---------|-----------|
| `internal/storage` | Persistence (DB open, channels, messages, sync state) | `main.go` — `storeChannel`, `storeMessages`, `updateSyncState`, `ensureSourceChannel` | `Store`, `Channel`, `Message`, `SyncState` |
| `internal/telegram` | Telegram client, auth, channel resolution, message fetching | `main.go` — CLI fetch flow | `Client`, `Message`, `NewTerminalAuth`, `ResolveChannel`, `FetchMessages` |
| `internal/summarizer` | LLM client abstraction and summarization service | `main.go` — `buildLLMClient`, TUI/CLI summarize flows | `Client`, `Service`, `ServiceOption`, `SummarizeQueueResult`, `NewOllamaClient`, `NewOpenRouterClient` |
| `internal/refresh` | Background source refresh orchestration | `main.go` — TUI refresh setup | `Service`, `RefreshResult`, `NewTelegramFetcher` |
| `internal/source` | Source registry and interface | `main.go` — TUI registry construction | `Registry`, `Source` |
| `internal/source/*` | Concrete source implementations (telegram, rss, reddit, hackernews) | `main.go` — registered into `source.Registry` | `NewTelegramSource`, `NewRSSSource`, `NewRedditSource`, `NewHNSource` |
| `internal/tui` | Interactive terminal UI | `main.go` — TUI launch | `NewApp`, `AppOption`, `WithRefresh`, `WithSummarize`, `RefreshService`, `SummarizeService` |

## Non-Obvious Behaviors

- **Backward-compat config migration**: If `llm.provider` is empty but `openrouter.api_key` is set, `Load()` silently migrates the old `openrouter` section into the new `llm` config format (`config.go:85-92`). The legacy `OpenRouterConfig` struct is still parsed and its defaults applied first, so the migration picks up those defaults.

- **LLM timeout defaults differ by provider**: Ollama gets 120s, OpenRouter gets 30s — a 4× difference. These only apply when `timeout_seconds` is omitted from config (`config.go:101-108`).

- **Ollama eagerly validates at startup**: `buildLLMClient` performs a health check AND verifies the requested model exists before returning. If the model isn't pulled, it fails with an actionable error message suggesting `ollama pull` (`main.go:319-324`). OpenRouter does no startup validation.

- **`isLocal` flag controls summarizer behavior**: `buildLLMClient` returns a `bool isLocal` that's `true` only for Ollama. This is passed as `summarizer.WithLocalModel()` option, meaning the summarizer service behaves differently for local vs. cloud models (`main.go:110-112`).

- **Reddit sort defaults happen in main, not config**: Config validation doesn't set a default for `SourceConfig.Sort`. The default `"hot"` is applied in `main.go:74-76` during registry construction. Similarly, HackerNews defaults `feed="top"` and `limit=30` in main (`main.go:80-88`), not in config. The config test at `config_test.go:394-396` explicitly documents that Sort is empty from config.

- **Registry presence changes refresh adapter**: If `registry.List()` is empty, the TUI gets `refresh.Service` directly. If sources exist, it gets the `registryRefreshAdapter` wrapper which calls `RefreshSources` instead of whatever `RefreshAll` the base service implements (`main.go:93-98`). These are different code paths.

- **`ensureSourceChannel` silently swallows errors**: If the DB lookup or channel creation fails, it logs a warning and continues (`main.go:338-353`). The TUI will still launch but that source won't have a channel record, which could cause downstream issues.

- **Messages stored one-at-a-time**: `storeMessages` calls `store.Messages().Create()` in a loop with no batching or transaction wrapping (`main.go:236-249`). A failure mid-loop leaves partial data.

- **Sync checkpoint is max message ID as string**: `updateSyncState` converts the highest `msg.ID` (int) to a string checkpoint via `strconv.Itoa` (`main.go:267`). This is the only sync mechanism — there's no offset-based pagination state.

- **Refresh interval minimum is enforced by defaulting, not clamping**: Setting `interval_minutes: -5` doesn't error — it silently becomes 30 via the `<= 0` check (`config.go:111-113`). Setting it to `1` would be accepted.

## Test Coverage Shape

**Well-tested:**
- `config.Load()` has ~25 test functions covering all sub-config types, defaults, validation errors, backward-compat migration, and all source type validations. This is thorough.
- `buildLLMClient` has 5 tests covering OpenRouter happy path, Ollama happy path, Ollama with missing model, empty provider (nil return), and unknown provider. Uses `httptest.NewServer` to mock Ollama endpoints.

**Conspicuously absent:**
- No tests for `storeChannel`, `storeMessages`, `updateSyncState`, or `ensureSourceChannel` — the core CLI data flow is untested at the unit level.
- No tests for the adapter types (`registryRefreshAdapter`, `summarizeServiceAdapter`) or the registry construction logic in the TUI branch.
- No integration tests that exercise the full main flow (even with mocked boundaries).
- The `--summarize` CLI path and the TUI startup path have zero test coverage.
- Config test for HackerNews default feed (`TestLoad_SourcesHackerNewsDefaultFeed`) tests that `Limit` is `0` when omitted from config, but `main.go` defaults it to `30` — this gap between config and runtime defaults is documented only implicitly.
