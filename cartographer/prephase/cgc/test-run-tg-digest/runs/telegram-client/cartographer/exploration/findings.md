---
scope: internal/telegram/client.go
files_explored: 4
boundary_packages: 1
generated: 2026-03-21
---

## Purpose

`internal/telegram` provides the MTProto connection layer for the application. Callers (primarily `main.go`) construct a `Client`, call `Run` with an `AuthFlow` and a callback, and receive a live `*tg.Client` handle inside that callback to pass downstream. The package also owns the `Message` domain type — a three-field struct (`ID`, `Text`, `Timestamp`) that is the shared data contract for all source subsystems (`source/telegram`, and by reference in tests for `source/hackernews`, `source/rss`, `source/reddit`).

## Architecture

```
[main.go] ──8 calls──► Client (client.go)
                            │
                ┌───────────┼───────────────┐
                ▼           ▼               ▼
        FileSessionStorage  AuthFlow    [gotd/td/telegram]
        (session.go)        interface       │
            │               │               ▼
        [filesystem]    TerminalAuth   [Telegram MTProto API]
        0600 session    (auth.go)
        file                │
                        [os.Stdin/Stdout]

[internal/source/*] ◄── Message{ID, Text, Timestamp}
                         ResolveChannel()
                         FetchMessages()
                    (messages.go — no Run dependency)
```

**Key interfaces and signatures**

```go
// AuthFlow — thin re-export of gotd's UserAuthenticator; no new methods
type AuthFlow interface {
    auth.UserAuthenticator
}

// Entry point for all Telegram operations
func (c *Client) Run(ctx context.Context, auth AuthFlow, f func(ctx context.Context) error) error

// Returns nil before/after Run; valid only inside f callback
func (c *Client) API() *tg.Client

// Shared domain type — de-facto message contract across all source subsystems
type Message struct {
    ID        int
    Text      string
    Timestamp time.Time
}

func ResolveChannel(ctx context.Context, api *tg.Client, username string) (*tg.InputChannel, error)
func FetchMessages(ctx context.Context, api *tg.Client, channel *tg.InputChannel, limit int, debug bool) ([]Message, error)
```

**Patterns**

- **Run/callback pattern** (`client.go:33–61`): `NewClient` is inert; the gotd `telegram.Client` is not constructed until `Run` is called. `c.api` is set inside the gotd callback immediately before `f` is invoked, ensuring the caller's function always has an authenticated, live handle.
- **AuthFlow re-export** (`auth.go:14–17`): `AuthFlow` embeds `auth.UserAuthenticator` verbatim. It adds no methods — its only purpose is to avoid leaking the `gotd/td/telegram/auth` package type into client.go's public signature.
- **Sentinel error translation** (`session.go:19–21`): `FileSessionStorage` maps `os.IsNotExist` → `session.ErrNotFound`. This is a required contract: gotd's `client.Run` uses the sentinel to distinguish "no session yet, prompt for auth" from a real I/O failure.

## Data Flow

**First-run authentication → live API handle**

```
main.go
  └─ client.Run(ctx, NewTerminalAuth(), f)
       └─ os.MkdirAll(sessionDir, 0700)            // filesystem
       └─ telegram.NewClient(apiID, apiHash, opts)   // gotd
            └─ FileSessionStorage.LoadSession()
                 └─ os.ReadFile → not found → session.ErrNotFound
                 // gotd interprets ErrNotFound as "start fresh auth"
       └─ Auth().Status() → Authorized: false
       └─ client.authenticate(ctx, authFlow)
            └─ auth.NewFlow(authFlow, SendCodeOptions{})
            └─ Auth().IfNecessary(ctx, flow)
                 // gotd calls: authFlow.Phone() → stdin prompt
                 //             authFlow.Code()  → stdin prompt
                 //             authFlow.AcceptTermsOfService() → silent accept
       └─ c.api = c.client.API()
       └─ f(ctx)  // caller receives live *tg.Client
```

**Subsequent run (cached session)**

```
client.Run(ctx, auth, f)
  └─ FileSessionStorage.LoadSession()
       └─ os.ReadFile → json.Unmarshal(data, &stored []byte) → session bytes
  └─ Auth().Status() → Authorized: true
  └─ f(ctx)  // auth flow skipped entirely — headless operation
```

**Message fetch flow**

```
f(ctx):
  api := client.API()                                    // *tg.Client
  ch, _ := ResolveChannel(ctx, api, "@channelname")
       └─ strings.TrimPrefix(username, "@")
       └─ api.ContactsResolveUsername(...)
       └─ scan resolved.Chats for *tg.Channel → InputChannel{ID, AccessHash}
  msgs, _ := FetchMessages(ctx, api, ch, limit, false)
       └─ api.MessagesGetHistory(...)
       └─ switch on MessagesMessages / MessagesMessagesSlice / MessagesChannelMessages
       └─ extractMessages: drop MessageEmpty, MessageService, empty .Message text
       └─ []Message{ID, Text, time.Unix(msg.Date, 0)}
```

## Boundaries

| Boundary | Role | Consuming files | Coupling |
|---|---|---|---|
| `github.com/gotd/td/telegram` | MTProto client construction and lifecycle | `client.go` | direct |
| `github.com/gotd/td/tg` | API types: `*tg.Client`, `tg.Message*`, `tg.Channel`, `tg.AuthSentCode` | `client.go`, `messages.go`, `auth.go` | direct |
| `github.com/gotd/td/telegram/auth` | `UserAuthenticator` interface; `NewFlow`, `SendCodeOptions` | `client.go`, `auth.go` | interface-mediated |
| `github.com/gotd/td/session` | `session.Storage` interface; `session.ErrNotFound` sentinel | `session.go` | interface-mediated |
| `[filesystem]` | Session directory creation; session file read/write | `client.go`, `session.go` | direct |
| `[os.Stdin / os.Stdout]` | Interactive terminal auth prompts | `auth.go` | direct |
| `[Telegram MTProto API]` | Network: channel resolution, message history | `messages.go` | direct |
| `internal/source/*` | Consumes `Message`, `ResolveChannel`, `FetchMessages` | — | direct |

## Non-Obvious Behaviors

- **`API()` is a trap for out-of-scope callers** (`client.go:64–66`): `c.api` is `nil` until the gotd callback fires inside `Run`. Any code that calls `client.API()` and stores the result, then uses it after `Run` returns (or before it is called), will get a nil pointer dereference. There is no error return — the nil is silent.

- **`Client` cannot be safely reused** (`client.go:41–43`): `Run` overwrites `c.client` unconditionally. A second call to `Run` on the same instance overwrites the previous `telegram.Client` with no synchronization. The struct is effectively single-use.

- **Session bytes are double-encoded on disk** (`session.go:27–29, 35–40`): `StoreSession` calls `json.Marshal(data []byte)` — a byte slice marshals to a base64 JSON string. `LoadSession` calls `json.Unmarshal(fileData, &stored []byte)`. This is intentional: the on-disk file is a JSON base64 string, not raw bytes. Treating it as a regular JSON object or raw binary will break it.

- **`extractMessages` silently drops messages with no count reported** (`messages.go:91–140`): callers receive fewer items than `limit` with no indication of how many were filtered. Media-only posts (no `.Message` text), service messages, and `MessageEmpty` are all discarded without error or log.

- **`Message.Timestamp` uses local timezone** (`messages.go:115`): `time.Unix(int64(msg.Date), 0)` uses the system's local timezone, not UTC. Telegram's `Date` field is a Unix epoch value so the instant is correct, but the `time.Time` representation carries local zone info. Callers comparing or formatting timestamps without explicit `.UTC()` will see local-time display.

- **`FetchMessages` will error on future gotd response variants** (`messages.go:80–82`): the `default` branch in the response-type switch returns `fmt.Errorf("unexpected messages type: %T", history)`. A gotd upgrade that introduces a new response type will break message fetching silently (no compile error) until the type switch is updated.

- **`AcceptTermsOfService` silently accepts** (`auth.go:59–62`): the method receives `tg.HelpTermsOfService` but returns `nil` without showing or logging the ToS content. This is invisible to users running the application.

- **`debug` flag leaks structured Telegram data to stdout** (`messages.go:98–133`): `fmt.Printf("[DEBUG] ... %#v\n", m)` prints full gotd message structs including all fields. If `debug: true` reaches production (it is passed as a parameter, not a build tag), it floods stdout with unstructured output that may include message text.

## Test Coverage Shape

The `internal/telegram` package has no test files in scope. The structured node data and hints confirm that test coverage of this package comes indirectly: `source/hackernews`, `source/rss`, and `source/reddit` test files reference `telegram.Message` as the expected return type, exercising the struct definition. The `Client`, `FileSessionStorage`, `TerminalAuth`, `ResolveChannel`, and `FetchMessages` behaviors have no unit test coverage — all require either a live Telegram connection or interactive terminal input, making them integration-only in practice. The absence of tests for `FileSessionStorage` is the most actionable gap: it has no network or interactive dependencies and could be tested against the filesystem.
