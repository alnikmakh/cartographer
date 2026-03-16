---
scope: internal/tui/app.go
files_explored: 15
boundary_packages: 4
generated: TIMESTAMP
---

## Purpose

The `internal/tui` package provides an interactive terminal UI for browsing daily message digests, managing content sources, and triggering refresh/summarize operations. It is consumed by `cmd/digest/main.go` as the user-facing frontend of the tg-digest application — the single entry point is `NewApp(store, ...opts)` which returns a Bubble Tea model ready to run with `tea.NewProgram`.

## Architecture

**Dependency diagram**

```
                     [cmd/digest]†
                          │
                          ▼
  types.go ◄──────── app.go ──────────► [storage]†
    ▲  ▲               │  │
    │  │          ┌─────┘  └──────┐
    │  │          ▼               ▼
    │  │    dashboard.go    channels.go
    │  │       │                  
    │  │       ▼                  
    │  │  filter_overlay.go       
    │  │       │                  
    │  └───────┼──► filter.go     
    │          │                  
    │          ▼                  
    │     help.go                 
    │                             
    ├── keys.go                   
    └── styles.go                 

  † boundary packages
  [storage] = tg-digest/internal/storage
  [cmd/digest] = cmd/digest/main.go
  types.go also imports [refresh]† and [summarizer]† for interface types
```

**Key interfaces and signatures**

```go
// app.go — public API
type App struct { /* ... */ }
type AppOption func(*App)
func NewApp(store storage.Store, opts ...AppOption) App
func WithRefresh(svc RefreshService, autoRefresh bool, interval time.Duration) AppOption
func WithSummarize(svc SummarizeService) AppOption
func (a App) Init() tea.Cmd
func (a App) Update(msg tea.Msg) (tea.Model, tea.Cmd)
func (a App) View() string

// types.go — service interfaces
type RefreshService interface {
    RefreshAll(ctx context.Context) (*refresh.RefreshResult, error)
    RefreshFiltered(ctx context.Context, sourceNames []string) (*refresh.RefreshResult, error)
}
type SummarizeService interface {
    SummarizeUnsummarized(ctx context.Context) (*summarizer.SummarizeQueueResult, error)
    SummarizeFiltered(ctx context.Context, channelIDs []int64) (*summarizer.SummarizeQueueResult, error)
}

// types.go — display models
type SummaryItem struct {
    ChannelName, Summary, SourceType string
    MessageCount int; Date time.Time
}
type ChannelItem struct {
    ID int64; Title, Username, SourceType string; AddedAt time.Time
}

// filter.go
type SourceFilter struct { Types, Names map[string]bool }
func (f SourceFilter) IsEmpty() bool
func (f SourceFilter) Match(sourceType, sourceName string) bool
func (f SourceFilter) MatchingChannelIDs(channels []ChannelItem) []int64
func (f SourceFilter) MatchingSourceNames(channels []ChannelItem) []string
func (f SourceFilter) FilterLabel(totalSources int) string
```

**Patterns**

- **Elm Architecture (Bubble Tea)** — `App` is the root `tea.Model`; child models (`dashboardModel`, `channelsModel`, `helpModel`, `filterOverlayModel`) follow the same `Update`/`View` contract. Messages flow up through commands, state flows down through struct embedding.
- **Functional Options** — `NewApp` accepts `AppOption` closures (`WithRefresh`, `WithSummarize`) for optional dependency injection of services.
- **Message Vocabulary** — `types.go` defines 14 message types forming a closed event protocol. All async results arrive as typed messages; no callbacks or channels.
- **Wizard State Machine** — `channelsModel` uses an `addStep` enum (`addStepType` → `addStepName` → `addStepURL`) to drive a three-step add-source flow with distinct key handlers per step.

## Data Flow

**Flow 1: Loading summaries for a date**

1. `App.Init()` calls `loadSummariesCmd(now)` — returns a `tea.Cmd` closure
2. The closure calls `store.Channels().List(ctx)` to get all channels
3. For each channel, calls `store.MessageSummaries().GetByChannelAndDate(ctx, id, start, end)` — boundary crossing to `[storage]`†
4. Builds `[]SummaryItem` with bullet-formatted summaries (each `MessageSummary.Summary` prefixed with "• ")
5. Returns `summariesLoadedMsg{date, summaries}`
6. `App.Update` receives msg → sets `loading=false`, delegates to `dashboard.Update`
7. `dashboardModel.Update` stores summaries, resets cursor/scroll/expanded state

**Flow 2: Filtered refresh + summarize**

1. User presses `r` on dashboard → `App.handleKeyMsg` checks `refreshSvc != nil && !loading`
2. Calls `refreshFilteredCmd(dashboard.filter)` — resolves `SourceFilter` to source names via `filter.MatchingSourceNames(channels.channels)`
3. Calls `refreshSvc.RefreshFiltered(ctx, sourceNames)` — boundary crossing to `[refresh]`†
4. Returns `refreshCompleteMsg{result, err, lastRefresh, filtered}`
5. On success, `App.Update` triggers `loadSummariesCmd` + `loadChannelsCmd` to reload data
6. If `autoRefresh` is enabled, also re-schedules `scheduleAutoRefresh()`

**Flow 3: Adding a source**

1. User presses `a` in Sources tab → `channelsModel.handleNormalKey` enters `addMode`
2. Step 1 (`addStepType`): up/down to select from `sourceTypeOptions`, enter to confirm
3. Step 2 (`addStepName`): raw rune input into `addNameInput`, enter to advance
4. Step 3 (`addStepURL`): raw rune input into `addURLInput`, enter emits `addSourceMsg`
5. `App.handleKeyMsg` intercepts the command result, calls `addSourceCmd(msg)`
6. `addSourceCmd` checks for duplicate via `store.Channels().GetByUsername` — returns `errMsg` if exists
7. Calls `store.Channels().Create` (telegram) or `store.Channels().CreateNonTelegram` (other types) — boundary crossing to `[storage]`†
8. Returns `sourceAddedMsg{}` → `App.Update` reloads channels

## Boundaries

| Boundary | Role | Used By | Key Types |
|----------|------|---------|-----------|
| `internal/storage` | Persistence — channel CRUD, message summary queries | `app.go` (direct `Store` usage) | `storage.Store`, `storage.Channel` |
| `internal/refresh` | Fetches new messages from sources | `app.go` (via `RefreshService` interface) | `refresh.RefreshResult` |
| `internal/summarizer` | LLM summarization of messages | `app.go` (via `SummarizeService` interface) | `summarizer.SummarizeQueueResult` |
| `cmd/digest` | CLI entry point, constructs `App` | imports `NewApp`, `WithRefresh`, `WithSummarize` | — |

## Non-Obvious Behaviors

- **Errors auto-clear after 5 seconds.** Every `errMsg` increments an `errID` counter and schedules an `errClearMsg` with that ID. Only the matching ID clears the error, preventing stale clears from racing with newer errors. (`app.go:119-125`)

- **Sub-model commands are eagerly executed in `handleKeyMsg`.** When a child model returns a `tea.Cmd`, `App.handleKeyMsg` calls `cmd()` immediately (line 287) to inspect the result type and intercept `loadSummariesMsg`, `deleteChannelMsg`, and `addSourceMsg`. This breaks the standard Bubble Tea pattern of returning commands for the runtime to execute — it works but means child commands execute synchronously in the Update cycle.

- **Refresh and summarize are filter-aware.** Pressing `r` or `s` doesn't refresh/summarize all sources — it respects the current dashboard filter. `refreshFilteredCmd` resolves the filter to source names, `summarizeFilteredCmd` resolves to channel IDs. An empty filter (no filtering active) passes `nil`, which the services interpret as "all". (`app.go:532-553`)

- **Auto-refresh reschedules even on error.** If a refresh fails, `refreshCompleteMsg` handling still calls `scheduleAutoRefresh()` so the timer keeps ticking. If a refresh tick arrives while already loading, it skips the refresh and reschedules. (`app.go:161-164`, `192-198`)

- **Telegram sources use a different creation path.** `addSourceCmd` branches on `sourceType == "telegram"` to call `store.Channels().Create` vs `store.Channels().CreateNonTelegram` for all other types. (`app.go:574-578`)

- **Filter overlay treats "all selected" as "no filter".** `buildFilter()` checks if every source is selected and returns an empty `SourceFilter{}` rather than a filter with all names. This avoids pointless per-name filtering in downstream queries. (`filter_overlay.go:98-108`)

- **`f` and `F` are distinct filter modes.** Lowercase `f` cycles through source types one at a time (empty → telegram → rss → reddit → hackernews → empty). Uppercase `F` opens the checkbox overlay for per-source selection. The cycle resets to no filter after hackernews. (`dashboard.go:108-130`, `132-137`)

- **Dashboard content height is `height - 4`.** The app reserves 4 lines for chrome (tab bar, two dividers, status bar) and passes the remainder to sub-models. (`app.go:96`)

- **The `Right` key binding does not include `l`.** Unlike `Left` which binds both `left` arrow and `h`, `Right` only binds `right` arrow — `l` is reserved for `Toggle` (expand/collapse). This is an intentional asymmetry in vim-style navigation. (`keys.go:47-54`)

## Test Coverage Shape

All 8 source files have corresponding test files (100% file coverage). Total: ~100 test functions.

**Well-tested:**
- All message routing paths in `App.Update` — view switching, error handling, refresh/summarize completion, auto-refresh scheduling
- Dashboard date navigation, cursor behavior, expand/collapse, scroll-to-cursor logic, text wrapping with ANSI-aware width
- Channels list navigation, delete confirmation (d → y/esc), complete add-source wizard flow through all 3 steps
- Filter overlay selection, toggle, select-all/none, confirm/cancel, and filter construction semantics
- `SourceFilter` matching logic — empty filters, type-only, name-only, intersection

**Behavioral contracts revealed by tests:**
- `TestApp_MultiSourceIntegration` creates real SQLite storage and verifies end-to-end with multiple source types — this is an integration test, not just mocked
- Dashboard tests verify cursor clamping at bounds and state reset on data reload
- Filter overlay tests confirm that all-selected produces an empty filter (the "no filter" optimization)

**Conspicuously absent:**
- No tests for `View()` output at specific terminal dimensions (width/height edge cases in scroll logic)
- No tests for `addSourceCmd`'s duplicate-detection or telegram vs non-telegram branching — the async commands that hit storage are tested only through integration tests
- No test for `scheduleAutoRefresh` timing behavior or the "skip refresh if already loading" path
