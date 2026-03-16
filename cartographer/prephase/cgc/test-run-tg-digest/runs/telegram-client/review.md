# Review: telegram-client findings.md

Reviewed against source code in `/home/dev/project/tg-digest/internal/telegram/`.

## Scores

- **Accuracy score**: 9/10
- **Completeness score**: 8/10
- **Usefulness score**: 9/10

## Inaccuracies Found

1. **Consumer claim about `refresh` package is inaccurate.** The document states consumers are "primarily `cmd/digest/main.go` and the `refresh` package." The `refresh` package (`internal/refresh/telegram.go`) never imports `internal/telegram`. It receives a raw `*tg.Client` (gotd type) and has its own duplicated channel resolution and message extraction logic. The actual direct consumers are `cmd/digest/main.go` and `internal/source/telegram/telegram.go`. The coupling with `refresh` is indirect, bridged through `main.go` calling `client.API()` and passing the result to `refresh.NewTelegramFetcher()`.

2. **Minor line range imprecision.** `messages.go:22-38` for ResolveChannel body -- the `strings.TrimPrefix` call is on line 21, not 22. `messages.go:91-139` for `extractMessages` -- the function's closing brace is on line 140. These are trivial off-by-ones with no practical impact.

All other claims verified as correct:
- All function signatures match exactly.
- All line number references (aside from the two noted above) are accurate.
- The session double-encoding behavior (json.Marshal on []byte producing base64) is correctly identified and explained.
- The type switch in ResolveChannel only matching `*tg.Channel` is correct (line 32).
- Empty text messages being silently dropped at lines 108-111 is correct.
- Phone number caching in TerminalAuth at lines 31-33 is correct.
- SignUp always failing at lines 55-57 is correct.
- Debug mode using `%#v` at line 99 is correct.
- Session directory 0700 / file 0600 permissions are correct.
- The `authenticate` method wrapping with `auth.NewFlow` and `auth.IfNecessary` at lines 68-70 is correct.
- No test files exist in `internal/telegram/` (confirmed by directory listing).

## Missing Important Details

1. **`internal/refresh/telegram.go` duplicates core logic.** This file contains its own `extractMessages` function and channel resolution code that closely parallels `messages.go`. This duplication is architecturally significant -- a bug fix in one would need to be applied to both. The findings document does not mention this.

2. **`internal/source/telegram` wrapper package.** There is a separate `internal/source/telegram` package (with tests at `internal/source/telegram/telegram_test.go`) that wraps this package's functionality behind the `source.Source` interface with checkpoint-based fetching. This is the primary integration point for the refresh pipeline and is worth noting for anyone trying to understand how the telegram client fits into the larger system.

3. **`FetchMessages` passes `limit` directly to the Telegram API with no client-side pagination.** If the API returns fewer messages than requested, that is all the caller gets. There is no accumulation loop. This is a practical limitation relevant to anyone using or modifying this code.

4. **`FetchMessages` constructs an `InputPeerChannel` intermediary.** Lines 45-48 convert the `*tg.InputChannel` parameter to `*tg.InputPeerChannel` for the API call. This conversion step is not mentioned in the data flow, though it matters for anyone modifying the fetch logic.

5. **`MessagesChannelMessages` is the response variant actually used for channels.** The type switch handles three response variants, but in practice channels return `MessagesChannelMessages`. The other two (`MessagesMessages`, `MessagesMessagesSlice`) apply to non-channel contexts. Knowing which path executes matters for debugging.

6. **`TerminalAuth.AcceptTermsOfService` silently auto-accepts** (line 60-62, returns nil). This has potential compliance implications that may be worth flagging.

## Overall Assessment

This is a high-quality architectural document. The vast majority of claims -- all function signatures, nearly all line references, data flow steps, boundary classifications, and non-obvious behaviors -- are directly verifiable against the source code. The single meaningful inaccuracy (misidentifying the `refresh` package as a direct consumer) is an understandable error given the indirection through the source interface layer. The document would give a new developer or AI agent a reliable mental model of the telegram client package, its API surface, and its subtle behaviors. The main gap is the absence of information about the `refresh` package's duplicated logic and the `internal/source/telegram` wrapper, which matter for understanding the full integration picture.
