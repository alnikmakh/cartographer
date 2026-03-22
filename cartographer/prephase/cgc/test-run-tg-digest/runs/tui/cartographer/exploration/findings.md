Now the findings.md narrative:

---
scope: internal/tui/app.go
files_explored: 15
boundary_packages: 2
generated: 2026-03-21
---

## Purpose

`internal/tui` is the terminal user interface for the tg-digest application. Its sole entry point, `NewApp(store storage.Store, opts ...AppOption) App`, returns a Bubble Tea root model that `cmd/digest` runs via `tea.NewProgram`. From the perspective of its caller, the package provides a complete, self-contained TUI: tab navigation between a summary dashboard and a source manager, date navigation, per-source filtering, and keyboard-triggered refresh and summarization — all mediated through optional service interfaces so the UI can be used in a storage-only mode without network capabilities.

## Architecture

```
[cmd/digest] ──────── NewApp() ──────────────────────────────────────┐
                                                                      │
                                ┌─────────────────── app.go ─────────┤
                                │  App (orchestrator)                 │
                                │  - activeView: dashboard | channels │
                                │  - showHelp bool                    │
                                │  - loading / errID / spinner        │
                                │  - refreshSvc / summarizeSvc        │
                                │                                     │
                    ┌───────────┼──────────────────────────────┐      │
                    │           │                              │      │
             dashboard.go  channels.go                    help.go     │
             (presenter)   (presenter)                  (presenter)   │
                    │           │                                      │
             filter.go   types.go ◄─ all msg types, service ifaces   │
             (model)      shared display types                         │
                    │                                                  │
         filter_overlay.go                                            │
         (presenter)                                                   │
                    │                                                  │
         keys.go  styles.go  (config/shared)                          │
                                                                      │
[internal/storage] ◄── direct calls in tea.Cmd closures ─────────────┘
[RefreshService]   ◄── interface-mediated (types.go defines interface)
[SummarizeService] ◄── interface-mediated (types.go defines interface)
```

**Key interfaces and signatures (from source):**

```go
// Public API surface consumed by cmd/digest
func NewApp(store storage.Store, opts ...AppOption) App
func WithRefresh(svc RefreshService, autoRefresh bool, interval time.Duration) AppOption
func WithSummarize(svc SummarizeService) AppOption

// Service interfaces defined in types.go (dependency inversion)
type RefreshService interface {
    RefreshAll(ctx context.Context) (*refresh.RefreshResult, error)
    RefreshFiltered(ctx context.Context, sourceNames []string) (*refresh.RefreshResult, error)
}
type SummarizeService interface {
    SummarizeUnsummarized(ctx context.Context) (*summarizer.SummarizeQueueResult, error)
    SummarizeFiltered(ctx context.Context, channelIDs []int64) (*summarizer.SummarizeQueueResult, error)
}

// Filter type used across dashboard, overlay, and commands
type SourceFilter struct {
    Types map[string]bool   // empty = all types
    Names map[string]bool   // empty = all names (within Types)
}
func (f SourceFilter) IsEmpty() bool
func (f SourceFilter) Match(sourceType, sourceName string) bool
func (f SourceFilter) MatchingChannelIDs(channels []ChannelItem) []int64   // nil = all
func (f SourceFilter) MatchingSourceNames(channels []ChannelItem) []string // nil = all
```

**Patterns:**

- **Elm architecture** — all sub-models are value types (`App`, `dashboardModel`, `channelsModel`, etc.); `Update` returns new copies; `Init`/`Update`/`View` are pure.
- **Functional options** — `AppOption` keeps `NewApp` minimal; the TUI degrades gracefully to read-only if no `RefreshService` or `SummarizeService` is provided.
- **Dependency inversion** — `RefreshService` and `SummarizeService` are defined in `types.go` inside the `tui` package. Only `types.go` imports `internal/refresh` and `internal/summarizer`; all other files in the package see only the local interface.
- **Global key singleton** — `keys` (declared in `keys.go`) is a package-level var holding all `key.Binding` instances; every sub-model pattern-matches against it rather than defining per-model key configs.
- **Centralized styles** — `styles.go` is the sole style definition file; `filter_overlay.go` is the only exception, constructing a local `boxStyle` at render time to apply a dynamic terminal-width-dependent box width.

## Data Flow

**Flow 1: Initial load**

```
tea.Program.Start()
  → App.Init()
      → tea.Batch(
            spinner.Tick,
            loadSummariesCmd(today),   // store.Channels().List + store.MessageSummaries().GetByChannelAndDate
            loadChannelsCmd(),         // store.Channels().List
            scheduleAutoRefresh()      // optional: tea.Tick(interval) → autoRefreshTickMsg
        )
  → summariesLoadedMsg{date, []SummaryItem} → App.Update → dashboard.Update
  → channelsLoadedMsg{[]ChannelItem}        → App.Update → channels.Update
                                                         → dashboard.channels = items
```

**Flow 2: Manual filter-aware refresh (r key)**

```
KeyMsg('r') → App.handleKeyMsg
  → a.refreshSvc != nil && !a.loading
  → refreshFilteredCmd(a.dashboard.filter)  // captures filter snapshot at key-press time
      → filter.MatchingSourceNames(a.channels.channels)  // nil = all
      → refreshSvc.RefreshFiltered(ctx, sourceNames)
      → refreshCompleteMsg{result, err, lastRefresh, filtered}
  → App.Update(refreshCompleteMsg)
      → loadSummariesCmd(currentDate) + loadChannelsCmd()  // reload after success
```
Note: auto-refresh via `autoRefreshTickMsg` calls `refreshCmd()` → `refreshSvc.RefreshAll(ctx)`, bypassing the filter entirely. This is intentional; the test `TestApp_AutoRefreshIgnoresFilter` documents this contract.

**Flow 3: Filter overlay → dashboard filter update**

```
KeyMsg('F') → dashboard.Update
  → newFilterOverlayModel(m.channels, m.filter)  // initializes checkboxes from current filter
  → m.showFilterOverlay = true

KeyMsg('enter') inside overlay → filterOverlayModel.Update
  → buildFilter(): allSelected → SourceFilter{} | subset → SourceFilter{Names: {...}}
  → return filterOverlayConfirmMsg{filter}

filterOverlayConfirmMsg → App.Update   (dual-dispatch: App intercepts, forwards to dashboard)
  → dashboard.Update(msg)
      → m.filter = msg.filter
      → m.showFilterOverlay = false
      → m.scrollOffset = 0; m.cursor = 0
```

## Boundaries

| Boundary | Role | Consuming files | Key types | Coupling |
|---|---|---|---|---|
| `internal/storage` | Persistence | `app.go` (all DB commands) | `storage.Store`, `storage.Channel`, `ChannelRepository`, `MessageSummaryRepository` | direct |
| `cmd/digest` | Caller / entrypoint | — | `NewApp`, `WithRefresh`, `WithSummarize`, `AppOption` | direct |
| `internal/refresh` | Result type only | `types.go` | `refresh.RefreshResult` | interface-mediated |
| `internal/summarizer` | Result type only | `types.go` | `summarizer.SummarizeQueueResult` | interface-mediated |
| `charmbracelet/bubbles/key` | Key binding declarations | `keys.go` | `key.Binding`, `key.NewBinding` | direct |
| `charmbracelet/lipgloss` | Visual styling | `styles.go`, `filter_overlay.go` | `lipgloss.Style`, `lipgloss.Color` | direct |

`internal/refresh` and `internal/summarizer` are imported only in `types.go` for their result struct types. All other TUI files see only the `RefreshService` / `SummarizeService` interfaces.

## Non-Obvious Behaviors

- **Eager sub-view command execution breaks BubbleTea dispatch** (`app.go:285-303`). When a sub-view's `Update` returns a command, `handleKeyMsg` immediately calls `result := cmd()` and pattern-matches the result rather than returning the command to the runtime. This means `loadSummariesMsg`, `deleteChannelMsg`, and `addSourceMsg` produced by sub-views never travel through the normal BubbleTea event loop — they are intercepted and re-dispatched synchronously. Any middleware or command interceptor added at the program level will not see these messages.

- **Error auto-clear uses an incrementing ID to avoid stale clears** (`app.go:113-125`). When an error is set, `errID` is incremented and a `tea.Tick(5s)` fires `errClearMsg{id: currentErrID}`. On receipt, the clear only applies if `msg.id == a.errID`. A newer error arriving before the tick fires will have bumped `errID`, so the old tick's clear is silently ignored.

- **Auto-refresh is always unfiltered; manual refresh respects the filter** (`app.go:192-198, 253-258`). `autoRefreshTickMsg` calls `refreshCmd()` → `RefreshAll(ctx)`. The `r` key calls `refreshFilteredCmd(a.dashboard.filter)` → `RefreshFiltered(ctx, sourceNames)`. These are intentionally different; the test `TestApp_AutoRefreshIgnoresFilter` (app_test.go:590) explicitly documents this distinction.

- **`filterOverlayConfirmMsg` takes a dual-dispatch path** (`app.go:208-214`, `dashboard.go:38-43`). The message is handled in `App.Update`, which forwards it to `dashboard.Update`. The App-level handler is needed because the overlay can also emit this message from outside the dashboard's key-forwarding path (e.g., if App has broader message handling in future). The current effect is that `dashboard.Update` receives the message twice in different scenarios — once via App forwarding and once when App routes it as a regular key-result from the dashboard sub-model.

- **`expanded` map survives filter changes, keyed by filtered-slice index** (`dashboard.go:90-95`). Pressing `f` to cycle the type filter resets `cursor` and `scrollOffset` to 0, but leaves `expanded` intact. Indices in `expanded` now refer to positions in the new filtered slice, not the old one — so a previously expanded card may visually appear expanded on a completely different source. Pressing `e` (expand-all) or `c` (collapse-all) clears this.

- **`SourceFilter` AND semantics between Types and Names** (`filter.go:22-33`). When both `Types` and `Names` are set, `Match` requires both to pass. In practice the filter picker overlay (`filter_overlay.go`) only ever produces `Names`-only filters; `Types`-only filters come from the `f`-key cycle in dashboard. A combined filter is theoretically possible but no UI path creates one currently.

- **`MatchingChannelIDs` / `MatchingSourceNames` return `nil` (not `[]T{}`) for empty filters** (`filter.go:37-63`). Downstream service methods (`RefreshFiltered`, `SummarizeFiltered`) treat `nil` as "all" — this is the load-bearing nil-means-all contract. Callers must not conflate nil with an empty selection.

- **filterOverlayModel's `confirmed`/`cancelled` fields are test-only observability** (`filter_overlay.go:27-28`). The parent (dashboard) reads state via the emitted message, not these fields. They exist solely so tests can assert on the model state without parsing rendered output.

- **Add-source wizard step 3 (`addStepURL`) is named "URL" but carries different semantics per source type** (`channels.go:267-280`). For Telegram it is a `@username`; for Reddit it is a subreddit name; for HackerNews it is a feed type (`top`/`best`/`new`/...); for RSS it is a URL. The field is stored as `addURLInput` and forwarded verbatim as `addSourceMsg.url`.

- **`addNameInput` whitespace guard is incomplete** (`channels.go:145`). `addStepName` advances on `m.addNameInput != ""` without trimming — a name of spaces passes validation and becomes a channel `Title` and `Username` in storage.

## Test Coverage Shape

Coverage is comprehensive and structurally sound. Every sub-model has a dedicated test file (`app_test.go`, `channels_test.go`, `dashboard_test.go`, `filter_overlay_test.go`, `filter_test.go`, `help_test.go`).

**Strengths:**
- `app_test.go` uses a real SQLite store (`t.TempDir`) for all storage paths — no storage mocking. Only `RefreshService` and `SummarizeService` are mocked. This means the DB interaction contract is integration-tested.
- `TestApp_AutoRefreshIgnoresFilter` explicitly documents and tests the auto-vs-manual refresh divergence.
- `dashboard_test.go` validates cursor-driven auto-scroll via `TestDashboard_ScrollFollowsCursor`, using ANSI-aware width measurement (`lipgloss.Width`) rather than naive `len()`.
- `filter_test.go` covers AND semantics, nil-return behavior, and all `FilterLabel` branches.

**Gaps:**
- The stale `expanded` map behavior after filter changes is not explicitly tested — the risk is structural and would need a test that cycles the filter and checks card identity, not just position.
- The dual-dispatch path for `filterOverlayConfirmMsg` (App intercepts + forwards to dashboard) is not directly tested as a path; tests confirm the end-state but not the routing.
- Whitespace-only name acceptance in the add-source wizard has no test.
