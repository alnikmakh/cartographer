# Edge Queue

## Relevant Edges

FORMAT: - [ ] [dN] source_file:line function → target_file:line function — edge_type
PROVEN: - [x] [dN] (same) — SUMMARY: what goes in, what happens, what comes out

edge_type: call | DI | event | config | middleware | re-export

- [x] [d1] client.go:33 Run → session.go FileSessionStorage constructor — DI
  SUMMARY: At client.go:39, Run() instantiates FileSessionStorage{Path: c.session}, creating a new session storage object with the session file path. This object implements the session.Storage interface (session.go:11-14) and is passed as a dependency to telegram.NewClient() at lines 41-43 via the Options struct (SessionStorage: sessionStorage). The FileSessionStorage manages MTProto session persistence: LoadSession (session.go:17) reads and JSON-decodes the session blob from disk, returning session.ErrNotFound if the file is absent; StoreSession (session.go:35) JSON-encodes and writes the session blob to disk with restricted permissions (0600). This DI pattern decouples the Telegram client from storage implementation, allowing the session blob to persist across reconnections and preserving authentication state.
- [x] [d1] client.go:33 Run → client.go:68 authenticate — call
  SUMMARY: At client.go:54, Run() calls c.authenticate(ctx, auth) when status.Authorized is false. The authenticate() function (defined at client.go:68-71) wraps the supplied AuthFlow into a gotd auth.NewFlow (auth.go external) with SendCodeOptions and passes it to c.client.Auth().IfNecessary() to execute the authentication flow. The AuthFlow parameter (an interface) is passed through unchanged, allowing the caller to inject custom authentication logic (e.g., TerminalAuth from auth.go). This call initiates the MTProto authentication handshake if the session is fresh or expired.
- [x] [d1] auth.go:30 Phone → auth.go:64 prompt — call
  SUMMARY: At tg-digest/internal/telegram/auth.go:35, the Phone() method (implementing auth.UserAuthenticator) calls prompt("Enter phone number (with country code, e.g., +1234567890): ") to interactively read the user's phone number from stdin. The prompt() helper (defined at line 64) prints the message, creates a bufio.Reader on os.Stdin, reads a line, and returns the trimmed text. Phone() caches the result in a.phone (line 40) and returns it. This enables the TerminalAuth authenticator to gather the first credential in Telegram's phone-based authentication flow.
- [x] [d1] auth.go:45 Password → auth.go:64 prompt — call
  SUMMARY: At tg-digest/internal/telegram/auth.go:46, the Password() method (implementing auth.UserAuthenticator) calls prompt("Enter 2FA password: ") to interactively read the user's two-factor authentication password. The prompt() helper reads from stdin (line 64-71), using the same stdin reader pattern. This call is invoked by the gotd auth framework only when Telegram requires 2FA (after the user successfully authenticates with phone + OTP code), making it conditional on account security settings.
- [x] [d1] auth.go:50 Code → auth.go:64 prompt — call
  SUMMARY: At tg-digest/internal/telegram/auth.go:51, the Code() method (implementing auth.UserAuthenticator) calls prompt("Enter the code sent to your Telegram: ") to interactively read the one-time passcode (OTP) that Telegram sends to the user's registered phone or app. The prompt() helper reads stdin and returns the trimmed code (line 64-71). This is invoked by gotd after Phone() completes, as the second step in the standard phone-based authentication sequence before any 2FA password is requested.
- [x] [d1] messages.go:44 FetchMessages → messages.go:91 extractMessages — call
  SUMMARY: At messages.go:44-88, FetchMessages() fetches message history from a resolved Telegram channel via api.MessagesGetHistory (line 50), receiving one of three response types: MessagesMessages, MessagesMessagesSlice, or MessagesChannelMessages (lines 61-79). For each type, FetchMessages immediately calls extractMessages(h.Messages, debug) at lines 67, 73, and 79 to filter and transform the raw message data. The extractMessages() function (defined at line 91) takes []tg.MessageClass and performs three transformations: (1) type-asserts to filter only *tg.Message entries, discarding MessageEmpty and MessageService variants; (2) filters out messages with empty text (line 108); (3) converts each valid *tg.Message into a simplified Message struct (lines 112-116), extracting ID (msg.ID), text (msg.Message), and timestamp (Unix conversion of msg.Date). The function returns []Message with only messages containing text content. This separation of concerns allows FetchMessages to handle API response variance while extractMessages isolates the filtering and type-conversion logic, producing a clean, normalized output for downstream processing.

## Irrelevant Edges (noted, not explored)

FORMAT: - source_file:line function → target — SKIPPED: reason

- client.go:33 Run → telegram.NewClient (github.com/gotd/td) — SKIPPED: External gotd/td package call that creates the underlying Telegram MTProto client. Session storage is passed via Options struct for framework to manage persistence lifecycle.
- client.go:68 authenticate → auth.NewFlow (github.com/gotd/td) — SKIPPED: External gotd/td auth package that wraps UserAuthenticator into a phone/OTP/2FA flow handler.
- client.go:68 authenticate → c.client.Auth().IfNecessary (github.com/gotd/td) — SKIPPED: External gotd/td framework method that executes authentication if user is not already authorized.
- auth.go:30,45,50 Phone/Password/Code → bufio.NewReader, reader.ReadString, fmt.Print, strings.TrimSpace — SKIPPED: Standard library I/O (bufio, fmt, os, strings) for reading user input from terminal.
- session.go:17 LoadSession → os.ReadFile, json.Unmarshal — SKIPPED: Standard library file I/O and JSON deserialization for reading persisted MTProto session blob from disk.
- session.go:35 StoreSession → json.Marshal, os.WriteFile — SKIPPED: Standard library JSON serialization and file I/O for writing persisted MTProto session blob to disk with 0600 permissions.
- messages.go:20 ResolveChannel → api.ContactsResolveUsername (github.com/gotd/td) — SKIPPED: External gotd/td Telegram API call that resolves a channel @username into InputChannel metadata (ChannelID + AccessHash) via the Contacts service.
- messages.go:44 FetchMessages → api.MessagesGetHistory (github.com/gotd/td) — SKIPPED: External gotd/td Telegram API call that fetches message history from a channel with limit and offset pagination.
- messages.go:20,44 ResolveChannel/FetchMessages → fmt.Errorf, strings.TrimPrefix — SKIPPED: Standard library string formatting and manipulation (fmt for error wrapping, strings for @-prefix trimming).
