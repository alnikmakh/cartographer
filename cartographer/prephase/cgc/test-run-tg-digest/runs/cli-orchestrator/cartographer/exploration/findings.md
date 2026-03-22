---
scope: cmd/digest/main.go
files_explored: 4
boundary_packages: 6
generated: 2026-03-21
---

## Purpose

`cmd/digest` is the application entry point and sole wiring layer for tg-digest. It owns all CLI flag parsing, config loading, service construction, and dispatch to one of two operating modes. Callers interact with it as a binary, not a library — it has no exported API surface. The bundled `internal/config` package is its only reusable output, consumed exclusively by `main.go` to parse YAML configuration into typed structs used by every downstream service.

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │           cmd/digest/main.go                │
                    │           (entry-point / orchestrator)      │
                    │                                             │
                    │  flags: --config --channel --limit          │
                    │         --debug --summarize --tui           │
                    │                                             │
                    │  helpers: storeChannel, storeMessages,      │
                    │           updateSyncState, buildLLMClient,  │
                    │           ensureSourceChannel               │
                    │                                             │
                    │  adapters: registryRefreshAdapter           │
                    │            summarizeServiceAdapter          │
                    └─────────────────────────────────────────────┘
         │                │               │              │
         ▼                ▼               ▼              ▼
  ┌─────────────┐  ┌──────────────┐  ┌────────┐  ┌────────────┐
  │ config.Load │  │[tui.NewApp]  │  │[storage│  │ [telegram] │
  │ (bundled)   │  │ implements   │  │ .Store]│  │ client/    │
  └─────────────┘  │ RefreshSvc   │  └────────┘  │ resolver/  │
         │         │ SummarizeSvc │               │ fetcher]   │
         ▼         └──────────────┘               └────────────┘
  ┌─────────────┐        ▲
  │ YAML file   │        │ bidirectional via interface
  │ (os.ReadFile│        │
  │ yaml.v3)    │  ┌─────┴──────────────────────────┐
  └─────────────┘  │ [refresh] [source] [summarizer] │
                   │ wired by main, invoked via TUI  │
                   └────────────────────────────────┘
```

**Two operating modes:**

- **CLI mode** (`--channel`): one-shot flow — resolve channel → storeChannel → FetchMessages → storeMessages → updateSyncState → optional SummarizeUnsummarized
- **TUI mode** (`--tui`): builds the full service graph (refresh pipeline, source registry, optional LLM), then hands off to `tui.NewApp` running inside `tea.NewProgram`

**Key signatures (verified from source):**

```go
// config package
func Load(path string) (*Config, error)

type Config struct {
    Telegram TelegramConfig   // api_id, api_hash, session_file
    Storage  StorageConfig    // db_path
    LLM      LLMConfig        // provider, model, ollama_url, openrouter_api_key, timeout_seconds
    Refresh  RefreshConfig    // auto_enabled, interval_minutes
    Sources  []SourceConfig   // type, name, url, subreddit, sort, feed, limit
    OpenRouter OpenRouterConfig // legacy migration source only
}

// main package (unexported, verified)
func buildLLMClient(ctx context.Context, cfg config.LLMConfig) (summarizer.Client, bool, error)
func storeChannel(ctx context.Context, store storage.Store, ch *tg.InputChannel, username string) (*storage.Channel, error)
func storeMessages(ctx context.Context, store storage.Store, channelID int64, messages []telegram.Message) error
func updateSyncState(ctx context.Context, store storage.Store, channelID int64, messages []telegram.Message) error
func ensureSourceChannel(ctx context.Context, store storage.Store, sc config.SourceConfig)
```

**Patterns:**

- **God-file orchestrator** — `main.go` wires all six boundary packages in a single file with no sub-packages. All helper functions, both adapter types, and both dispatch flows live here.
- **Adapter bridging** — `registryRefreshAdapter` and `summarizeServiceAdapter` are thin stateless structs that implement `tui.RefreshService` and `tui.SummarizeService` respectively, satisfying the TUI's interface requirements without the TUI depending on concrete service types.
- **Backward-compat migration** — `config.Load` transparently promotes the old `openrouter:` YAML section into the unified `llm:` section; `OpenRouterConfig` is retained in the `Config` struct solely as a migration staging area.

## Data Flow

**CLI fetch flow:**
```
flag.Parse() → config.Load(configPath) → *Config
    → storage.Open(cfg.Storage.DBPath) → Store
    → telegram.NewClient(apiID, apiHash, sessionFile)
    → client.Run(ctx, auth, func() {
        telegram.ResolveChannel(ctx, api, username) → *tg.InputChannel
        storeChannel(ctx, store, ch, username)      → *storage.Channel
        telegram.FetchMessages(ctx, api, ch, limit) → []telegram.Message
        storeMessages(ctx, store, channelID, msgs)  → (loop, one insert per msg)
        updateSyncState(ctx, store, channelID, msgs) → SyncState.Upsert
        [if --summarize > 0]
        buildLLMClient(ctx, cfg.LLM) → summarizer.Client
        summarizer.NewService(...).SummarizeUnsummarized(ctx)
    })
```

**TUI mode wiring:**
```
config.Load → *Config
storage.Open → Store
telegram.NewClient → client.Run(ctx, auth, func() {
    refresh.NewTelegramFetcher(client.API()) → Fetcher
    refresh.NewService(fetcher, store, 50)   → *refresh.Service
    source.NewRegistry() + cfg.Sources loop  → *source.Registry
    [if len(registry) > 0]
        registryRefreshAdapter{svc, registry} → tui.RefreshService
    [else]
        refreshSvc directly                   → tui.RefreshService
    buildLLMClient(ctx, cfg.LLM)              → summarizer.Client, isLocal
    summarizer.NewService(client, model, store) → *summarizer.Service
    summarizeServiceAdapter{svc}              → tui.SummarizeService
    tui.NewApp(store, WithRefresh(...), WithSummarize(...)) → tea.Model
    tea.NewProgram(app, tea.WithAltScreen()).Run()
})
```

**Config loading:**
```
os.ReadFile(path) → raw YAML bytes
yaml.Unmarshal    → Config struct
[OpenRouter legacy migration if cfg.LLM.Provider == "" && cfg.OpenRouter.APIKey != ""]
[Apply LLM/Refresh defaults]
cfg.validate()    → error on missing required fields
expandPath(session_file, db_path) → absolute paths
```

## Boundaries

| Boundary Package | Role | Consuming Call Sites | Key Types | Coupling |
|---|---|---|---|---|
| `internal/storage` | persistence layer | `storeChannel`, `storeMessages`, `updateSyncState`, `ensureSourceChannel`, TUI wiring | `Store`, `Channel`, `Message`, `SyncState` | direct |
| `internal/telegram` | Telegram MTProto client | CLI fetch flow, TUI wiring | `NewClient`, `ResolveChannel`, `FetchMessages`, `Message` | direct |
| `internal/refresh` | multi-source refresh pipeline | TUI wiring only | `NewTelegramFetcher`, `NewService`, `RefreshResult` | direct |
| `internal/source` | source registry + adapters | TUI wiring only | `NewRegistry`, `Registry`, `Source` (+ 4 concrete subtypes) | direct |
| `internal/summarizer` | LLM summarization service | `buildLLMClient`, CLI `--summarize` path, TUI wiring | `Client`, `NewOllamaClient`, `NewOpenRouterClient`, `NewService`, `SummarizeQueueResult` | direct |
| `internal/tui` | bubbletea TUI app | TUI wiring only; main.go *implements* tui interfaces | `NewApp`, `RefreshService`, `SummarizeService` | interface-mediated (bidirectional) |
| `github.com/gotd/td/tg` | Telegram API types | `storeChannel` parameter type | `tg.InputChannel` | direct |
| `github.com/charmbracelet/bubbletea` | TUI event loop | TUI wiring | `tea.NewProgram`, `p.Run` | direct |

## Non-Obvious Behaviors

- **`--summarize N` ignores N.** The flag accepts a day-count but `SummarizeUnsummarized(ctx)` at line 187 processes all unsummarized messages regardless of the value. The CLI output even says "today + yesterday" as a hardcoded string. There is no date filtering.

- **Bidirectional coupling with TUI.** `main.go` calls `tui.NewApp`, but the TUI also calls back into `main.go`-defined adapters at runtime via `tui.RefreshService` and `tui.SummarizeService`. The TUI package does not depend on `refresh` or `summarizer` directly — `main.go` is the glue.

- **`ensureSourceChannel` silently discards errors.** If the DB lookup or `CreateNonTelegram` call fails, `log.Printf` is emitted and the function returns. TUI startup continues. The source will appear in the registry but have no corresponding DB channel record, which will cause display issues in the TUI.

- **`storeChannel` stores the username as the channel title.** `channel.Title = username` at line 222 is acknowledged in a comment ("We could enhance this by fetching actual title"). Channels created via the CLI path will display as `@durov` rather than "Pavel Durov" in the TUI.

- **Ollama startup is blocking and fail-fast.** `buildLLMClient` performs a live HTTP health check AND a model availability check before returning. If Ollama is configured but temporarily unreachable, the entire TUI launch fails — there is no graceful degradation to "no summarization available."

- **`refreshSvc` is used directly (bypassing registry) when no sources are configured.** At lines 94–98, if `registry.List()` is empty, `refreshSvc` (a `*refresh.Service`) is assigned directly as the `tui.RefreshService`. This means an empty config produces a TUI that can still attempt refreshes, though they would operate over zero sources.

- **Validation happens before path expansion.** `cfg.validate()` (line 115) checks `session_file` and `db_path` for emptiness on unexpanded paths. This has no practical impact since the checks are presence-only, but the ordering is surprising.

- **Reddit sort defaulting is split across two locations.** `config.Load` does not default `Sort` — it is intentionally left empty. main.go defaults it to `"hot"` at line 75 when constructing the registry. The config test explicitly documents this split.

## Test Coverage Shape

Coverage is narrow but well-targeted:

- **`main_test.go`** covers only `buildLLMClient`. It uses `httptest.NewServer` to mock both Ollama endpoints (`/` health, `/api/tags` model list) and exercises all three provider branches (ollama, openrouter, empty). Tests are self-contained. The five other helper functions (`storeChannel`, `storeMessages`, `updateSyncState`, `ensureSourceChannel`) and both adapter types have no unit tests.

- **`config_test.go`** is comprehensive: table-driven, fully isolated (temp files via `writeTestConfig`), and covers all source types, both LLM providers, the backward-compat migration, all validation error paths, and the intentional split-default for Reddit sort. This is the better-tested of the two files.
