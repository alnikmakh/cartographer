# Edge Queue

## Relevant Edges

FORMAT: - [ ] [dN] source_file:line function → target_file:line function — edge_type
PROVEN: - [x] [dN] (same) — SUMMARY: what goes in, what happens, what comes out

edge_type: call | DI | event | config | middleware | re-export

- [x] [d0] client.go:33 Run → client.go:68 authenticate — call (line 54)
  - SUMMARY: Run (tg-digest/internal/telegram/client.go:33) connects to Telegram and manages authentication. At line 54, Run calls authenticate() to handle the auth flow when the user is not yet authorized. authenticate() receives the AuthFlow parameter, wraps it in auth.NewFlow() (line 69), and calls c.client.Auth().IfNecessary() (line 70) to execute the authentication flow (phone→code→password prompts). Data: context.Context and AuthFlow interface passed to authenticate; authenticate then creates an auth.Flow object that prompts user for credentials via the AuthFlow implementation.

- [x] [d0] client.go:33 Run → auth.go:15 AuthFlow — interface_parameter
  - SUMMARY: Run (line 33) receives a parameter of type AuthFlow (auth.go:15-17: interface that extends auth.UserAuthenticator). Run passes this to authenticate() at line 54, which uses it to construct the authentication flow. AuthFlow defines the contract for authentication callbacks (Phone, Code, Password methods implemented by auth.go:20 TerminalAuth or similar). This is dependency injection of the auth strategy.

- [x] [d0] client.go:33 Run → session.go:12 FileSessionStorage — DI (line 39)
  - SUMMARY: Run (client.go:33) initializes the Telegram client connection and handles session persistence. At line 39, Run instantiates FileSessionStorage with the session file path (c.session field, set during NewClient at client.go:27). The instantiation is `sessionStorage := &FileSessionStorage{Path: c.session}` (client.go:39). This object is then injected as a dependency into telegram.NewClient via the SessionStorage field of telegram.Options (client.go:41-43). FileSessionStorage (session.go:12-14) is a struct that implements the gotd/td session.SessionStorage interface with two methods: LoadSession (session.go:17-31) loads serialized session bytes from disk via os.ReadFile and json.Unmarshal, and StoreSession (session.go:35-41) persists session bytes to disk via json.Marshal and os.WriteFile. Data flow: client path string → FileSessionStorage.Path field; when telegram.Client needs to persist or restore auth state, it calls FileSessionStorage.LoadSession/StoreSession which read/write the session file. This enables the Telegram connection to maintain authentication state across application restarts.
- [x] [d0] messages.go:44 FetchMessages → messages.go:91 extractMessages — call (lines 67,73,79)
  - SUMMARY: FetchMessages (tg-digest/internal/telegram/messages.go:44) fetches message history from a Telegram channel. It calls api.MessagesGetHistory() which returns one of three history types (*tg.MessagesMessages, *tg.MessagesMessagesSlice, *tg.MessagesChannelMessages). Depending on the type, it calls extractMessages() at lines 67, 73, or 79, passing h.Messages ([]tg.MessageClass slice) and debug (bool flag). extractMessages (line 91) filters and transforms the raw Telegram message objects: iterates through msgs (line 97), filters out empty text and non-message types (MessageEmpty, MessageService), and for valid tg.Message objects extracts ID, text content (msg.Message field), and Unix timestamp (line 115: time.Unix(int64(msg.Date), 0)). Returns []Message slice containing only valid messages with text content. FetchMessages returns this filtered result at line 88.

## Irrelevant Edges (noted, not explored)

FORMAT: - source_file:line function → target — SKIPPED: reason

- client.go:23 NewClient → (no outgoing) — SKIPPED: Constructor initializes Client struct fields (apiID, apiHash, session). No function calls.
- client.go:64 API → (no outgoing) — SKIPPED: Getter method returns c.api field. No function calls.
- auth.go:25 NewTerminalAuth → (no outgoing) — SKIPPED: Constructor initializes TerminalAuth struct. No function calls.
- session.go:17 LoadSession → os.ReadFile, json.Unmarshal, session.ErrNotFound — SKIPPED: Filesystem I/O via os.ReadFile() and JSON decoding via json.Unmarshal(). Reads and decodes MTProto session blob from disk. Uses session.ErrNotFound from external gotd/td SDK. Only standard library and external package calls.
- session.go:35 StoreSession → json.Marshal, os.WriteFile — SKIPPED: JSON encoding via json.Marshal() and filesystem I/O via os.WriteFile(). Encodes and persists MTProto session blob to disk with mode 0600. Only standard library calls.
- messages.go:20 ResolveChannel → api.ContactsResolveUsername — SKIPPED: Telegram API call via api.ContactsResolveUsername(). Resolves channel @username to InputChannel struct (ChannelID + AccessHash) using Telegram's ContactsResolveUsername RPC. External gotd/td SDK call.
