# Scout Context

## Entry Points

- tg-digest/internal/tui/dashboard.go:29 — newDashboardModel() constructor, initialises dashboardModel with a date and empty expanded map
- tg-digest/internal/tui/dashboard.go:36 — Update() bubbletea message handler; routes key events, filter changes, and summaries-loaded messages
- tg-digest/internal/tui/dashboard.go:156 — View() renders the full dashboard string; builds date nav bar, source cards, and scroll viewport
- tg-digest/internal/tui/dashboard.go:143 — filteredSummaries() applies the active SourceFilter and returns the visible SummaryItem slice
- tg-digest/internal/tui/dashboard.go:317 — applyScroll() clips a pre-built content string to the scroll offset and viewport height
- tg-digest/internal/tui/dashboard.go:346 — sourceTypeBadge() maps a source-type string to a short badge label ([TG], [RSS], [RD], [HN])

## Boundaries

Explore within:
- tg-digest/internal/tui/dashboard.go
- tg-digest/internal/tui/styles.go
- tg-digest/internal/tui/types.go
- tg-digest/internal/tui/keys.go

Do NOT explore:
- tg-digest/internal/tui/app.go (parent model, out of scope)
- tg-digest/internal/tui/channels.go
- tg-digest/internal/tui/filter*.go (filter overlay is a separate sub-model)
- tg-digest/internal/tui/help.go
- tg-digest/internal/storage/ (any non-tui package)
- tg-digest/internal/summarizer/ (any non-tui package)
- tg-digest/internal/sources/ (any non-tui package)

## Max Depth

4 hops from any entry point.

## Notes

- dashboardModel is a bubbletea component (not the root model); the root model lives in app.go and delegates to it.
- Source cards are collapsible: each card index is tracked in the `expanded map[int]bool` field. Toggle is bound to keys.Toggle; keys.ExpandAll and keys.CollapseAll operate on all visible cards at once.
- Cursor navigation is vim-style plus arrow keys: Up/Down move the cursor through filteredSummaries(); Left/Right navigate to the previous/next date and fire a loadSummariesMsg command.
- Message list rendering happens entirely inside View(): cards are built into a []string slice (cardLines), cardStartLines tracks each card's first line index for scroll-to-cursor logic, and the final slice is clipped to the viewport.
- Card expand/collapse state is stored by filtered index, not by source ID, so it resets whenever summaries reload (newDashboardModel or summariesLoadedMsg resets the map).
- Scroll is cursor-aware: View() computes effectiveScroll so the selected card is always visible without exposing a raw scrollOffset to callers; applyScroll() is used only for the empty-list path.
- All visual styling (dateStyle, helpDescStyle, selectedCardStyle, expandedArrowStyle, collapsedArrowStyle, sourceTypeBadgeStyle, summaryTextStyle) is imported from styles.go via package-level vars; no styles are defined inside dashboard.go.
- Key bindings referenced (keys.Left, keys.Right, keys.Up, keys.Down, keys.Toggle, keys.ExpandAll, keys.CollapseAll, keys.Filter, keys.FilterPicker) are defined in keys.go.
- filterTypeCycle (line 13) drives the quick-cycle filter: empty → telegram → rss → reddit → hackernews → empty. The full filter-picker overlay (keys.FilterPicker) delegates to filterOverlayModel defined in filter*.go files.
- SummaryItem and SourceFilter types are defined in types.go.
