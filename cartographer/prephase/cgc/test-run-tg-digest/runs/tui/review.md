# Review: TUI findings.md

## Scores

- **Accuracy score**: 9/10
- **Completeness score**: 8/10
- **Usefulness score**: 9/10

## Inaccuracies Found

1. **"state flows down through struct embedding"** -- The child models (`dashboardModel`, `channelsModel`, `helpModel`) are struct *fields* in `App`, not embedded types. Go "embedding" specifically means anonymous fields with promoted methods. This is struct composition via named fields. Minor terminology error but could confuse a Go developer.

2. **"14 message types forming a closed event protocol"** -- `types.go` defines 14 message types, but `filter_overlay.go` adds 2 more (`filterOverlayConfirmMsg`, `filterOverlayCancelMsg`), bringing the total to 16. The doc acknowledges these implicitly in the data flow but the stated count of 14 is incomplete. The doc does note "types.go defines 14 message types" which is technically accurate for that file alone, but the "closed event protocol" framing implies completeness.

3. **"All 8 source files have corresponding test files (100% file coverage)"** -- There are 8 non-test `.go` files (app, channels, dashboard, filter, filter_overlay, help, keys, styles) but only 6 test files. `keys_test.go` and `styles_test.go` do not exist. File coverage is 75%, not 100%. This is the most significant factual error in the document.

4. **"Total: ~100 test functions"** -- Actual count is 104. The approximation is reasonable but slightly understated.

5. **Delete confirmation described as "d -> y/esc"** in test coverage section -- The actual `Confirm` binding accepts both `y` and `enter`, and `Cancel` accepts both `n` and `esc`. The shorthand omits valid key alternatives.

## Missing Important Details

1. **Dead type `loadChannelsMsg`** -- Defined in `types.go` (line 71) but never referenced anywhere in handlers or commands. This dead code could confuse a developer trying to understand the channel reloading mechanism.

2. **`refreshCmd()` vs `refreshFilteredCmd()` distinction** -- The doc describes `refreshFilteredCmd` well but does not note that a separate `refreshCmd()` (app.go lines 512-522) exists that calls `RefreshAll` and is used exclusively by auto-refresh ticks. Manual `r` key always goes through `refreshFilteredCmd`. This means auto-refresh ignores the current filter while manual refresh respects it -- a significant behavioral difference.

3. **View rendering during loading** -- When `loading` is true, the `View()` method replaces the entire content area with a spinner (app.go lines 318-319). The active view's content is not visible during any data operation. This is a UX-relevant behavior worth documenting.

4. **`Confirm`/`Toggle` key overlap on `enter`** -- Both `keys.Confirm` (`y`, `enter`) and `keys.Toggle` (`enter`, `l`) bind the `enter` key. This overlap is managed by context (Confirm only active during delete confirmation in channels, Toggle only during normal dashboard navigation) but could cause subtle issues and is worth flagging as a design decision.

5. **Help model responds to `Cancel` key** -- `helpModel.Update` closes help on either `?` or the `Cancel` binding (`n`/`esc`). Pressing `n` while help is open will close it, which could surprise users expecting `n` to do nothing.

6. **Tab only cycles Dashboard and Channels** -- The `Tab` handler (app.go lines 267-274) only toggles between two views. Help is a separate modal overlay toggled by `?`, not part of the tab cycle. This is implied by the document but not explicitly stated.

## Verification of Key Claims

The following claims were all verified as correct against the source:

- All function signatures in the "Key interfaces and signatures" section match the code exactly
- The dependency diagram accurately reflects import relationships
- All three data flow walkthroughs (loading summaries, filtered refresh, adding a source) match the actual code paths
- All four boundary packages and their roles are correct
- Error auto-clear mechanism with errID counter (app.go:119-125) -- verified
- Sub-model cmd eager execution at line 287 -- verified, this is correctly identified as breaking standard Bubble Tea patterns
- Filter-aware refresh/summarize (app.go:532-553) -- verified
- Auto-refresh reschedules on error (app.go:161-164, 192-198) -- verified
- Telegram vs non-telegram creation branching (app.go:574-578) -- verified
- Filter overlay "all selected = no filter" optimization (filter_overlay.go:98-108) -- verified
- `f` vs `F` distinct filter modes (dashboard.go:108-137) -- verified
- Content height = height - 4 (app.go:96) -- verified
- Right key binding asymmetry with `l` reserved for Toggle (keys.go:47-54) -- verified
- `TestApp_MultiSourceIntegration` uses real SQLite storage -- verified (app_test.go:479)

## Overall Assessment

This is a high-quality architectural document with strong factual accuracy. The function signatures, data flow walkthroughs, boundary descriptions, and non-obvious behavior observations are nearly all correct, with line number references that check out against the source. The main errors are the overstated test file coverage claim (75% actual vs 100% claimed) and minor terminology issues. The document's greatest strength is its "Non-Obvious Behaviors" section, which surfaces genuinely non-obvious implementation details that would take significant code reading to discover. The missing detail about auto-refresh ignoring filters while manual refresh respects them is the most significant omission for a developer maintaining this code.
