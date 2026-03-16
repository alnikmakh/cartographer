---
scope: internal/telegram/client.go
files_explored: 4
boundary_packages: 4
generated: TIMESTAMP
---

## Purpose

This package provides the Telegram API integration layer for tg-digest. It lets callers connect to Telegram with persistent sessions, authenticate interactively via terminal prompts, resolve channel usernames, and fetch message history. Consumers (primarily `cmd/digest/main.go` and the `refresh` package) use `Client.Run()` to get an authenticated context, then call `ResolveChannel` and `FetchMessages` to retrieve channel content as simplified `Message` structs.

## Architecture

**Dependency diagram**

```
  auth.go ─── AuthFlow interface ───→ client.go
                                        │
  session.go ─ FileSessionStorage ──→───┘
                                        │
                                        ├──→ [gotd/td/telegram]†    (connection, options)
                                        ├──→ [gotd/td/telegram/auth]† (auth flow, send code)
                                        └──→ [gotd/td/tg]†          (API client)

  messages.go ── ResolveChannel, FetchMessages ──→ [gotd/td/tg]†

  † boundary: gotd/td library
  ‡ boundary: internal/storage (indirect — cmd layer bridges telegram.Message → storage.Message)
```

`client.go` orchestrates connection and auth. `messages.go` is independent — it takes a `*tg.Client` directly rather than going through `Client`, so callers must extract `client.API()` and pass it explicitly.

**Key interfaces and signatures**

```go
// auth.go
type AuthFlow interface {
    auth.UserAuthenticator  // embeds gotd's Phone, Code, Password, SignUp, AcceptTermsOfService
}

func NewTerminalAuth() *TerminalAuth

// client.go
type Client struct { /* unexported: client, api, apiID, apiHash, session */ }

func NewClient(apiID int, apiHash, sessionFile string) *Client
func (c *Client) Run(ctx context.Context, auth AuthFlow, f func(ctx context.Context) error) error
func (c *Client) API() *tg.Client

// messages.go
type Message struct { ID int; Text string; Timestamp time.Time }

func ResolveChannel(ctx context.Context, api *tg.Client, username string) (*tg.InputChannel, error)
func FetchMessages(ctx context.Context, api *tg.Client, channel *tg.InputChannel, limit int, debug bool) ([]Message, error)

// session.go
type FileSessionStorage struct { Path string }

func (s *FileSessionStorage) LoadSession(_ context.Context) ([]byte, error)
func (s *FileSessionStorage) StoreSession(_ context.Context, data []byte) error
```

**Pattern identification**

- **Strategy pattern** — `AuthFlow` interface decouples authentication strategy from the client. `TerminalAuth` is the sole implementation; callers could substitute a non-interactive authenticator.
- **Facade** — `Client.Run()` facades gotd's multi-step connect → check auth status → authenticate → execute workflow into a single call.
- **Adapter** — `FileSessionStorage` adapts file I/O to gotd's `session.SessionStorage` interface. `Message` struct adapts gotd's `tg.Message` to a simplified application model.

## Data Flow

**Flow 1: Authenticated session with message fetching (happy path)**

1. Caller creates client via `NewClient(apiID, apiHash, sessionFile)` — stores config, no I/O yet
2. Caller invokes `client.Run(ctx, auth, func)` — `client.go:33`
3. `Run` creates session directory with `os.MkdirAll` (0700 permissions) — `client.go:35`
4. `Run` instantiates `FileSessionStorage{Path: sessionFile}` — `client.go:39`
5. `Run` creates gotd `telegram.Client` with session storage and calls `client.Run()` — `client.go:41-45`
6. gotd loads session via `FileSessionStorage.LoadSession()` — reads JSON file, or returns `session.ErrNotFound` if absent — `session.go:17-31`
7. `Run` checks `client.Auth().Status(ctx)` — `client.go:48`
8. If not authorized, calls `authenticate()` which wraps `AuthFlow` in `auth.NewFlow` and calls `Auth().IfNecessary()` — `client.go:68-71`
9. `TerminalAuth` prompts for phone → code → optional 2FA password via stdin — `auth.go:30-52`
10. gotd stores session via `FileSessionStorage.StoreSession()` — writes JSON to disk with 0600 permissions — `session.go:35-41`
11. `Run` calls user-provided `f(ctx)` with authenticated context
12. Inside `f`, caller uses `client.API()` to get `*tg.Client`, calls `ResolveChannel(ctx, api, "@username")` — `messages.go:20`
13. `ResolveChannel` strips `@` prefix, calls `api.ContactsResolveUsername`, iterates `resolved.Chats` looking for `*tg.Channel` — `messages.go:22-38`
14. Caller calls `FetchMessages(ctx, api, channel, limit, debug)` — `messages.go:44`
15. `FetchMessages` calls `api.MessagesGetHistory`, type-switches on response variant, passes to `extractMessages()` — `messages.go:50-82`
16. `extractMessages` filters: keeps `*tg.Message` with non-empty `.Message` text, skips `MessageEmpty`, `MessageService`, and empty-text messages — `messages.go:91-139`
17. Returns `[]Message` with ID, Text, and Timestamp (converted from Unix epoch)

## Boundaries

| Boundary | Role | Used By | Key Types |
|----------|------|---------|-----------|
| `gotd/td/telegram` | Telegram client connection and options | `client.go` | `telegram.Client`, `telegram.Options` |
| `gotd/td/telegram/auth` | Authentication flow orchestration | `client.go`, `auth.go` | `auth.UserAuthenticator`, `auth.NewFlow`, `auth.SendCodeOptions`, `auth.UserInfo` |
| `gotd/td/tg` | Telegram API methods and types | `client.go`, `auth.go`, `messages.go` | `tg.Client`, `tg.Channel`, `tg.InputChannel`, `tg.Message`, `tg.MessageClass` |
| `gotd/td/session` | Session storage interface | `session.go` | `session.SessionStorage` (interface), `session.ErrNotFound` |
| `internal/storage` | Application persistence layer | None directly — bridged by `cmd` layer | `storage.Message` (separate from `telegram.Message`) |

## Non-Obvious Behaviors

- **Session data is double-encoded as JSON.** `FileSessionStorage.StoreSession` receives raw `[]byte` from gotd, then `json.Marshal`s it (producing a base64-encoded JSON string), then writes that to disk. `LoadSession` reverses this with `json.Unmarshal` into `[]byte`. This means the session file contains a JSON string of base64, not raw session bytes. — `session.go:26-28`, `session.go:36-38`

- **Messages with empty text are silently dropped.** `extractMessages` skips any `*tg.Message` where `.Message == ""` — this includes media-only messages (photos, videos, stickers) that have no caption. There is no way for callers to know messages were filtered. — `messages.go:108-111`

- **`ResolveChannel` only matches `*tg.Channel`, not supergroups or other chat types.** The type switch at `messages.go:31` only handles `*tg.Channel`. If a username resolves to a `*tg.Chat` or other type, it returns an error "is not a channel". In practice gotd represents supergroups as `*tg.Channel` with a flag, so this works for most public groups, but private groups resolved by username could fail.

- **`messages.go` functions are decoupled from `Client`.** `ResolveChannel` and `FetchMessages` are package-level functions taking `*tg.Client` as a parameter, not methods on `Client`. Callers must call `client.API()` to get the raw API handle. This means these functions could be used without the `Client` wrapper entirely.

- **`TerminalAuth.Phone` caches the phone number** after first prompt. Subsequent calls within the same auth flow return the cached value without re-prompting. — `auth.go:31-33`

- **`SignUp` always fails.** If Telegram requires account creation (phone not registered), `TerminalAuth.SignUp` returns a hard error. There's no fallback. — `auth.go:55-57`

- **Session directory is created with 0700 but session file with 0600.** `client.go:35` creates the parent directory, `session.go:40` writes the file. This is intentional — directory needs execute bit for traversal, file is owner-read/write only.

- **Debug mode in `FetchMessages` prints raw message structs with `%#v`.** When `debug=true`, every message is dumped with Go's verbose format including all fields. This could log sensitive message content to stdout. — `messages.go:99`

## Test Coverage Shape

No test files exist in the explored scope (`internal/telegram/`). All four files are source-only with no corresponding `_test.go` files. Given that this package makes real Telegram API calls and reads from stdin, testing would require either mocking the gotd client or integration tests with a real Telegram account. The `AuthFlow` interface does provide a seam for testing the auth orchestration without terminal interaction, but it is not exercised by any tests in scope.
