# Scout Context

## Entry Points

- tg-digest/internal/tui/app.go:57 — NewApp() constructs the root App model, applies functional options, initialises sub-models and spinner
- tg-digest/internal/tui/app.go:78 — Init() seeds the Bubble Tea runtime with the spinner tick, initial data loads, and optional auto-refresh schedule
- tg-digest/internal/tui/app.go:91 — Update() dispatches all incoming tea.Msg values; drives state transitions for loading, errors, view switching, and async results
- tg-digest/internal/tui/app.go:229 — handleKeyMsg() processes tea.KeyMsg; routes global keys (quit, help, refresh, summarize, tab) and forwards unhandled keys to the active sub-model
- tg-digest/internal/tui/app.go:308 — View() composes the full terminal frame: tab bar, active sub-view or loading/help overlay, error line, status bar

## Boundaries

Explore within:
- tg-digest/internal/tui/app.go
- tg-digest/internal/tui/types.go
- tg-digest/internal/tui/keys.go
- tg-digest/internal/tui/styles.go
- tg-digest/internal/storage/storage.go (Store interface only)

Do NOT explore:
- tg-digest/internal/tui/dashboard.go
- tg-digest/internal/tui/channels.go
- tg-digest/internal/tui/filter*.go
- tg-digest/internal/tui/help.go
- tg-digest/cmd/
- tg-digest/internal/telegram/
- tg-digest/internal/source/
- tg-digest/internal/refresh/
- tg-digest/internal/summarizer/
- tg-digest/internal/config/

## Max Depth

5 hops from any entry point.

## Notes

- The TUI follows the Bubble Tea Elm architecture: App implements tea.Model with Init/Update/View; all state is carried by value (App is a struct, not a pointer).
- Active view is tracked by the viewID enum (types.go:12-17): viewDashboard (0) and viewChannels (1). Tab key cycles between them in handleKeyMsg.
- Functional options pattern: WithRefresh (app.go:41) and WithSummarize (app.go:50) are the only two AppOption constructors; both are optional and gate their respective features via nil checks throughout Update.
- RefreshService (types.go:127-130) and SummarizeService (types.go:95-98) are interfaces defined in this package, not imported from their implementation packages. This keeps the TUI decoupled from concrete service types.
- Async operations follow a command/message round-trip: a tea.Cmd fires a goroutine that returns a typed tea.Msg (e.g. summariesLoadedMsg, refreshCompleteMsg, summarizeCompleteMsg). Update handles the result msg to clear loading state and trigger follow-on commands.
- Key bindings are centralised in keys.go as a single package-level keyMap var named `keys`. All key matching in handleKeyMsg uses key.Matches against fields of this struct.
- Error display is transient: errMsg sets a.err and starts a 5-second tea.Tick that sends errClearMsg with a matching ID to auto-dismiss (app.go:119-125).
- The loading flag gates both the spinner display in View and guards Refresh/Summarize key handlers from double-firing.
- switchViewMsg with view == -1 is a sentinel used by the help overlay to signal "close help" back up to App (app.go:217-221).
