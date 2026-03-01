# Telegram Package — Full Picture

> Package: `tg-digest/internal/telegram/`
> Framework: gotd/td (github.com/gotd/td) — Go MTProto client
> Files: client.go, auth.go, session.go, messages.go

## Architecture

The package is a thin wrapper around gotd/td. It provides four concerns:

1. **Connection lifecycle** (client.go) — wraps gotd's MTProto client
2. **Authentication** (auth.go) — interactive terminal auth via stdin
3. **Session persistence** (session.go) — JSON file-based session storage
4. **Message fetching** (messages.go) — channel resolution and history retrieval

All Telegram API calls must happen inside the callback passed to `Run()`. Outside that callback, there is no connection.

## Entry Points

| Symbol | Location | Purpose |
|---|---|---|
| `NewClient()` | client.go:23 | Constructs Client with apiID, apiHash, sessionFile. No connection yet. |
| `Run()` | client.go:33 | Connects to Telegram, handles auth, executes caller callback |
| `API()` | client.go:64 | Returns `*tg.Client` for raw API calls (only valid inside Run callback) |
| `NewTerminalAuth()` | auth.go:25 | Creates interactive authenticator for phone/OTP/2FA |
| `FileSessionStorage.LoadSession()` | session.go:17 | Reads MTProto session from disk |
| `FileSessionStorage.StoreSession()` | session.go:35 | Writes MTProto session to disk |
| `ResolveChannel()` | messages.go:20 | Resolves @username to InputChannel |
| `FetchMessages()` | messages.go:44 | Fetches recent messages from a channel |

## Key Types

### Client (client.go:14-20)
```go
type Client struct {
    client  *telegram.Client  // gotd MTProto client (set in Run)
    api     *tg.Client        // raw API client (set in Run callback)
    apiID   int               // Telegram app ID
    apiHash string            // Telegram app hash
    session string            // path to session file
}
```

### AuthFlow (auth.go:15-17)
```go
type AuthFlow interface {
    auth.UserAuthenticator  // embeds gotd's interface
}
```
Requires: `Phone()`, `Code()`, `Password()`, `SignUp()`, `AcceptTermsOfService()`

### TerminalAuth (auth.go:20-22)
```go
type TerminalAuth struct {
    phone string  // cached after first prompt
}
```
Concrete AuthFlow implementation. All methods delegate to `prompt()` (auth.go:64-72) for stdin reading via `bufio.NewReader(os.Stdin)`.

### FileSessionStorage (session.go:12-14)
```go
type FileSessionStorage struct {
    Path string
}
```
Implements gotd's `session.Storage` interface.

### Message (messages.go:13-17)
```go
type Message struct {
    ID        int
    Text      string
    Timestamp time.Time
}
```
Simplified representation — only text-bearing messages survive filtering.

## Call Chain: Connection & Authentication

```
Caller
  │
  ├─ NewClient(apiID, apiHash, sessionFile)        client.go:23
  │    └─ returns &Client{apiID, apiHash, session}  (no connection)
  │
  └─ client.Run(ctx, auth, callback)                client.go:33
       │
       ├─ os.MkdirAll(sessionDir, 0700)             client.go:35
       │    └─ ensures session directory exists
       │
       ├─ &FileSessionStorage{Path: c.session}       client.go:39
       │    └─ constructs session storage (DI into gotd)
       │
       ├─ telegram.NewClient(apiID, apiHash, Options{  client.go:41-43
       │    SessionStorage: sessionStorage})
       │    └─ creates gotd MTProto client with session storage injected
       │
       └─ c.client.Run(ctx, func)                    client.go:45
            │  └─ gotd manages MTProto connection lifecycle
            │
            ├─ c.api = c.client.API()                 client.go:46
            │    └─ captures raw *tg.Client for API calls
            │
            ├─ c.client.Auth().Status(ctx)            client.go:48
            │    └─ checks if session is already authorized
            │
            ├─ [if not authorized]
            │    └─ c.authenticate(ctx, auth)          client.go:54
            │         │                                client.go:68-71
            │         ├─ auth.NewFlow(authFlow, SendCodeOptions{})
            │         │    └─ wraps AuthFlow in gotd's flow runner
            │         │
            │         └─ c.client.Auth().IfNecessary(ctx, flow)
            │              └─ triggers phone auth sequence:
            │                   Phone() → OTP sent → Code() → Password() (if 2FA)
            │                   │
            │                   └─ TerminalAuth methods (auth.go:30-62)
            │                        each calls prompt() (auth.go:64-72)
            │                        └─ bufio.NewReader(os.Stdin).ReadString('\n')
            │
            └─ callback(ctx)                          client.go:59
                 └─ caller's function runs with active connection
                      can now call c.API() to get *tg.Client
```

### Session Flow (called by gotd internally)

```
gotd starts connection
  │
  ├─ LoadSession(ctx)                                session.go:17
  │    ├─ os.ReadFile(path)
  │    ├─ if file missing → session.ErrNotFound → fresh auth
  │    └─ json.Unmarshal → returns session bytes
  │
  └─ [after successful auth]
       └─ StoreSession(ctx, data)                    session.go:35
            ├─ json.Marshal(data)
            └─ os.WriteFile(path, encoded, 0600)
```

## Call Chain: Message Fetching

Must be called from inside the `Run()` callback with the `*tg.Client` from `c.API()`.

```
Inside Run callback
  │
  ├─ api := client.API()                             client.go:64
  │
  ├─ ResolveChannel(ctx, api, "@username")            messages.go:20
  │    ├─ strings.TrimPrefix(username, "@")           messages.go:21
  │    ├─ api.ContactsResolveUsername(ctx, request)   messages.go:23-25
  │    │    └─ Telegram API: resolves username to chat objects
  │    ├─ iterates resolved.Chats                     messages.go:30
  │    ├─ type-switches for *tg.Channel               messages.go:31-32
  │    └─ returns &tg.InputChannel{ChannelID, AccessHash}  messages.go:33-35
  │
  └─ FetchMessages(ctx, api, channel, limit, debug)   messages.go:44
       │
       ├─ constructs InputPeerChannel from InputChannel  messages.go:45-48
       │    └─ {ChannelID, AccessHash} — required by MessagesGetHistory
       │
       ├─ api.MessagesGetHistory(ctx, request)        messages.go:50-53
       │    └─ Telegram API: fetches message history with limit
       │
       ├─ type-switch on response                     messages.go:61-82
       │    ├─ *tg.MessagesMessages        → h.Messages  messages.go:62-67
       │    ├─ *tg.MessagesMessagesSlice   → h.Messages  messages.go:68-73
       │    └─ *tg.MessagesChannelMessages → h.Messages  messages.go:74-79
       │
       └─ extractMessages(rawMessages, debug)          messages.go:91-140
            │  called at lines 67, 73, 79
            │
            ├─ iterates []tg.MessageClass              messages.go:97
            ├─ type-switch per message                 messages.go:102
            │    ├─ *tg.Message (103-116)
            │    │    ├─ skip if msg.Message == ""     messages.go:108-110
            │    │    └─ Message{ID: msg.ID,
            │    │         Text: msg.Message,
            │    │         Timestamp: time.Unix(msg.Date, 0)}
            │    ├─ *tg.MessageEmpty (117) → skip
            │    └─ *tg.MessageService (122) → skip
            │
            └─ returns []Message (only text-bearing)   messages.go:139
```

## End-to-End Data Flow

```
@username (string)
  → ResolveChannel
    → *tg.InputChannel {ChannelID, AccessHash}
      → FetchMessages
        → InputPeerChannel (same IDs, different type for API)
          → MessagesGetHistory API call
            → tg.MessagesClass response (one of 3 variants)
              → extractMessages
                → []tg.MessageClass (raw array from response)
                  → type filtering (Message only, non-empty text)
                    → []Message {ID int, Text string, Timestamp time.Time}
```

## External Dependencies (boundary calls)

| Call Site | Target | What It Does |
|---|---|---|
| client.go:41 | `telegram.NewClient()` | Creates gotd MTProto client with credentials and session options |
| client.go:45 | `c.client.Run()` | Manages MTProto TCP connection lifecycle, invokes callback while connected |
| client.go:46 | `c.client.API()` | Returns gotd's raw `*tg.Client` for making Telegram API method calls |
| client.go:48 | `c.client.Auth().Status()` | Checks current authorization state with Telegram servers |
| client.go:69 | `auth.NewFlow()` | Wraps UserAuthenticator into gotd's auth flow runner with send-code options |
| client.go:70 | `c.client.Auth().IfNecessary()` | Runs full phone→OTP→password auth flow only if session is unauthorized |
| messages.go:23 | `api.ContactsResolveUsername()` | Telegram API: resolves @username string to channel/chat objects |
| messages.go:50 | `api.MessagesGetHistory()` | Telegram API: fetches message history from a peer with offset/limit pagination |
| session.go:18 | `os.ReadFile()` | Reads session file bytes from disk |
| session.go:40 | `os.WriteFile()` | Writes JSON-encoded session blob to disk with 0600 permissions |
| session.go:27 | `json.Unmarshal()` | Deserializes JSON session file into byte slice |
| session.go:36 | `json.Marshal()` | Serializes session byte slice into JSON for disk storage |
| client.go:35 | `os.MkdirAll()` | Creates session file parent directory if it doesn't exist |
| auth.go:66 | `bufio.NewReader(os.Stdin)` | Creates buffered reader for interactive terminal input |

## Design Notes

- **No global state.** Client holds all state. ResolveChannel and FetchMessages are stateless functions that take `*tg.Client` as a parameter.
- **DI for auth.** The AuthFlow interface allows swapping TerminalAuth for any custom authenticator without changing Client.
- **DI for session.** FileSessionStorage is injected into gotd via Options. A different storage backend (e.g., database) could replace it.
- **Session reuse.** If the session file exists and is valid, LoadSession returns it and gotd skips auth entirely. No phone/OTP prompt on subsequent runs.
- **No signup.** TerminalAuth.SignUp() returns an error (auth.go:56). The package assumes an existing Telegram account.
- **Debug output.** FetchMessages and extractMessages use `fmt.Printf` for debug output, not a logger interface. The `debug bool` parameter gates all debug prints.
- **Message filtering.** Only `*tg.Message` with non-empty `.Message` text survives. `MessageEmpty`, `MessageService`, and messages with media-only content (empty text) are silently discarded.
