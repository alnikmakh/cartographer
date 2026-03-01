# Scout Context

## Entry Points

- tg-digest/internal/tui/channels.go:28 — newChannelsModel() constructs the zero-value channels model
- tg-digest/internal/tui/channels.go:32 — channelsModel.Update() dispatches channelsLoadedMsg, channelDeletedMsg, and KeyMsg; routes to add/confirm/normal sub-handlers
- tg-digest/internal/tui/channels.go:64 — channelsModel.handleConfirmKey() handles the y/n delete confirmation prompt
- tg-digest/internal/tui/channels.go:80 — channelsModel.handleNormalKey() handles list navigation, delete trigger, and entering add mode
- tg-digest/internal/tui/channels.go:113 — channelsModel.handleAddKey() drives the three-step add-source wizard (type selection, name input, URL input)
- tg-digest/internal/tui/channels.go:178 — channelsModel.View() renders the source list or delegates to renderAddView()
- tg-digest/internal/tui/channels.go:235 — channelsModel.renderAddView() renders each wizard step (addStepType, addStepName, addStepURL)
- tg-digest/internal/tui/filter.go:17 — SourceFilter.IsEmpty() returns true when both Types and Names maps are empty
- tg-digest/internal/tui/filter.go:22 — SourceFilter.Match() tests a single source against both the Types and Names constraints
- tg-digest/internal/tui/filter.go:37 — SourceFilter.MatchingChannelIDs() resolves the filter to a concrete slice of int64 IDs for SQL queries
- tg-digest/internal/tui/filter.go:52 — SourceFilter.MatchingSourceNames() resolves the filter to source name strings for the refresh service
- tg-digest/internal/tui/filter.go:66 — SourceFilter.FilterLabel() produces a human-readable summary of the active filter state
- tg-digest/internal/tui/filter_overlay.go:34 — newFilterOverlayModel() constructs the overlay, pre-selecting items that match the current SourceFilter
- tg-digest/internal/tui/filter_overlay.go:46 — filterOverlayModel.Update() handles cursor movement, space-toggle, select-all/none, enter confirm, and esc cancel
- tg-digest/internal/tui/filter_overlay.go:98 — filterOverlayModel.buildFilter() converts the checkbox selection into a SourceFilter (empty filter if all selected)
- tg-digest/internal/tui/filter_overlay.go:119 — filterOverlayModel.View() renders the checkbox list inside a rounded lipgloss border box

## Boundaries

Explore within:
- tg-digest/internal/tui/channels.go
- tg-digest/internal/tui/filter.go
- tg-digest/internal/tui/filter_overlay.go
- tg-digest/internal/tui/styles.go
- tg-digest/internal/tui/types.go
- tg-digest/internal/tui/keys.go

Do NOT explore:
- tg-digest/internal/tui/app.go
- tg-digest/internal/tui/dashboard.go
- tg-digest/internal/tui/help.go
- tg-digest/internal/storage/ (or any other non-tui package)
- tg-digest/internal/fetcher/
- tg-digest/internal/bot/
- tg-digest/cmd/

## Max Depth

4 hops from any entry point.

## Notes

- channels.go owns the source list view: it shows all monitored sources with their type badge and add date, and supports keyboard navigation (up/down), delete with inline y/n confirmation, and an add-source wizard.
- The add-source wizard is a three-step multi-step form embedded directly in channelsModel. Step 1 (addStepType) picks from a fixed list of source types via cursor. Step 2 (addStepName) accepts free-text name input. Step 3 (addStepURL) accepts the URL or identifier, with a per-type prompt label. Completing step 3 emits addSourceMsg; Esc at any step cancels.
- channels.go communicates with the storage layer through message passing: it emits deleteChannelMsg and addSourceMsg, and receives channelsLoadedMsg and channelDeletedMsg from the parent app model. It does not call storage directly.
- SourceFilter (filter.go) is a value type with two independent constraint sets: Types (map[string]bool) and Names (map[string]bool). A source must pass BOTH non-empty constraints. An empty filter matches everything. The zero value is valid and means "all sources".
- filterOverlayModel (filter_overlay.go) is a transient modal UI for multi-select filtering. It is initialised with newFilterOverlayModel, pre-populates checkboxes from the current SourceFilter, and emits filterOverlayConfirmMsg (carrying the new SourceFilter) or filterOverlayCancelMsg on dismissal. If all sources are checked, buildFilter() returns an empty SourceFilter rather than enumerating every name.
- keys.go defines the shared key bindings (keys.Up, keys.Down, keys.Confirm, keys.Cancel, keys.Delete, keys.Add) referenced across all three files.
- styles.go provides all lipgloss styles used in View() calls (titleStyle, selectedStyle, unselectedStyle, helpDescStyle, confirmStyle, sourceTypeBadgeStyle, channelNameStyle, selectedCardStyle, messageCountStyle, primaryColor).
- types.go defines ChannelItem (the data record for a monitored source, including ID, Username, SourceType, AddedAt) and the addStep iota constants (addStepType, addStepName, addStepURL).
