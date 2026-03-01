# Scout Context

## Entry Points

- tg-digest/internal/telegram/client.go:23 — NewClient() constructs a Client wrapper with API credentials and session file path; no connection is made yet
- tg-digest/internal/telegram/client.go:33 — Run() connects to Telegram via MTProto, initialises FileSessionStorage, checks auth status, triggers authenticate() if needed, then calls the caller-supplied function
- tg-digest/internal/telegram/client.go:64 — API() returns the underlying *tg.Client for making raw Telegram API calls after Run() has established a connection
- tg-digest/internal/telegram/auth.go:25 — NewTerminalAuth() creates a TerminalAuth that satisfies AuthFlow; prompts the user interactively for phone, OTP code, and 2FA password
- tg-digest/internal/telegram/session.go:17 — FileSessionStorage.LoadSession() reads and JSON-decodes the MTProto session blob from disk; returns session.ErrNotFound when the file is absent
- tg-digest/internal/telegram/session.go:35 — FileSessionStorage.StoreSession() JSON-encodes and writes the MTProto session blob to disk with mode 0600
- tg-digest/internal/telegram/messages.go:20 — ResolveChannel() resolves a channel @username to a *tg.InputChannel (ChannelID + AccessHash) via ContactsResolveUsername
- tg-digest/internal/telegram/messages.go:44 — FetchMessages() fetches up to `limit` recent messages from a resolved InputChannel via MessagesGetHistory and returns []Message

## Boundaries

Explore within:
- tg-digest/internal/telegram/

Do NOT explore:
- tg-digest/internal/storage/ (no import relationship with the telegram package)
- tg-digest/internal/tui/
- tg-digest/internal/config/
- tg-digest/internal/source/
- tg-digest/internal/summarizer/
- tg-digest/internal/refresh/
- tg-digest/cmd/
- Any *_test.go files
- Any node_modules/ or vendor/ directories

## Max Depth

5 hops from any entry point.

## Notes

- The package is built on the gotd/td framework (github.com/gotd/td). All network I/O goes through telegram.Client.Run(), which manages the MTProto connection lifecycle; code that needs to call Telegram APIs must be placed inside the callback passed to Run().
- Authentication uses gotd's auth.NewFlow + auth.UserAuthenticator interface. The concrete implementation is TerminalAuth (auth.go), which prompts via stdin. Callers can supply a different AuthFlow implementation without changing Client.
- Session persistence is handled by FileSessionStorage (session.go), which satisfies gotd's session.Storage interface. The session blob is a JSON-encoded byte slice written to the path supplied to NewClient(). If the file is absent, LoadSession returns session.ErrNotFound and gotd treats the session as fresh, triggering the full phone-auth flow.
- The phone auth flow sequence is: Phone() -> Telegram sends OTP -> Code() -> optionally Password() for 2FA. SignUp() is intentionally unsupported; the package expects an existing Telegram account.
- ResolveChannel and FetchMessages are stateless helpers that take a *tg.Client directly; they must be called from inside a Run() callback after the client is authenticated and c.api has been assigned.
- FetchMessages handles three concrete response types from MessagesGetHistory: MessagesMessages, MessagesMessagesSlice, and MessagesChannelMessages. Only *tg.Message entries with non-empty .Message text are included in the returned slice; MessageEmpty and MessageService variants are silently discarded.
- The debug parameter on FetchMessages and extractMessages produces verbose printf output to stdout; it is not gated by a logger interface.
