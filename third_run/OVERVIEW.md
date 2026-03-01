# Explanation Map

## Entry Points

From CONTEXT.md:
- **client.go:23 NewClient()** — Constructs a Client wrapper with API credentials and session file path; no connection is made yet.
- **client.go:33 Run()** — Connects to Telegram via MTProto, initializes FileSessionStorage, checks auth status, triggers authenticate() if needed, then calls the caller-supplied function.
- **client.go:64 API()** — Returns the underlying *tg.Client for making raw Telegram API calls after Run() has established a connection.
- **auth.go:25 NewTerminalAuth()** — Creates a TerminalAuth that satisfies AuthFlow; prompts the user interactively for phone, OTP code, and 2FA password.
- **session.go:17 FileSessionStorage.LoadSession()** — Reads and JSON-decodes the MTProto session blob from disk; returns session.ErrNotFound when the file is absent.
- **session.go:35 FileSessionStorage.StoreSession()** — JSON-encodes and writes the MTProto session blob to disk with mode 0600.
- **messages.go:20 ResolveChannel()** — Resolves a channel @username to a *tg.InputChannel (ChannelID + AccessHash) via ContactsResolveUsername.
- **messages.go:44 FetchMessages()** — Fetches up to `limit` recent messages from a resolved InputChannel via MessagesGetHistory and returns []Message.

## Call Chain

**Client Initialization and Connection Flow:**

1. **client.go:33 Run() → session.go:12-14 FileSessionStorage (DI)**
   - Run() creates a FileSessionStorage instance at client.go:39: `sessionStorage := &FileSessionStorage{Path: c.session}`
   - This storage object is injected into telegram.NewClient() at client.go:41-43 via the Options struct
   - FileSessionStorage implements the gotd session.Storage interface and manages persisted authentication state

2. **client.go:33 Run() → client.go:68 authenticate() (call)**
   - After establishing the MTProto connection, Run() checks authorization status at client.go:48
   - If not authorized (client.go:53), Run() calls c.authenticate(ctx, auth) at line 54
   - authenticate() (defined at client.go:68-71) wraps the supplied AuthFlow into a gotd auth flow and executes the authentication handshake

**TerminalAuth Credential Collection Flow (auth.go):**

3. **auth.go:30 Phone() → auth.go:64 prompt() (call)**
   - TerminalAuth.Phone() (line 30) calls prompt("Enter phone number (with country code, e.g., +1234567890): ") at line 35
   - prompt() helper (line 64) prints the message to stdout via fmt.Print(), creates a bufio.Reader on os.Stdin, reads a line via reader.ReadString('\n'), trims whitespace, and returns the result
   - Result is cached in a.phone (line 40) for subsequent calls and returned to gotd auth framework to initiate phone-based authentication

4. **auth.go:45 Password() → auth.go:64 prompt() (call)**
   - TerminalAuth.Password() (line 45) calls prompt("Enter 2FA password: ") at line 46
   - prompt() helper reads user input from stdin (same pattern as Phone/Code)
   - Returned to gotd auth framework only if the account has two-factor authentication enabled; appears as the third step after successful Phone() + Code()

5. **auth.go:50 Code() → auth.go:64 prompt() (call)**
   - TerminalAuth.Code() (line 50) calls prompt("Enter the code sent to your Telegram: ") at line 51
   - prompt() helper reads the OTP code from stdin
   - Returned to gotd auth framework as the second authentication step, after Phone() but before any Password() (if 2FA is required)

## Key Types

- **Client (client.go:14-20)** — Wraps the gotd/td Telegram client. Fields: `client *telegram.Client` (underlying MTProto connection), `api *tg.Client` (API surface after authentication), `apiID int` and `apiHash string` (credentials), `session string` (file path for session storage).

- **FileSessionStorage (session.go:12-14)** — Implements the gotd session.Storage interface. Field: `Path string` (file system path to JSON-encoded session blob). Methods: LoadSession() returns deserialized session bytes or session.ErrNotFound; StoreSession() serializes and writes session bytes to disk with 0600 permissions.

- **AuthFlow (interface, imported from auth package)** — Defines the contract for authentication handlers. Passed through Run() → authenticate() to the gotd auth flow handler. The concrete implementation in this package is TerminalAuth (auth.go:25), which prompts users for phone number, OTP code, and optional 2FA password.

- **TerminalAuth (auth.go:20-27)** — Concrete implementation of auth.UserAuthenticator interface for terminal-based authentication. Field: `phone string` (cached phone number for caching across calls). Methods: Phone() (line 30) reads phone from stdin, Password() (line 45) reads 2FA password, Code() (line 50) reads OTP code. All credential methods call the prompt() helper (line 64) to display a message and read user input from stdout/stdin.

- **prompt() helper (auth.go:64-71)** — Writes a message to stdout via fmt.Print(), creates a bufio.Reader on os.Stdin, reads a line via reader.ReadString('\n'), returns trimmed text or error. Shared utility for all interactive credential collection in TerminalAuth.

## Data Flow

**Terminal Authentication Prompt Flow (TerminalAuth credential collection):**
- Input: AuthFlow interface (TerminalAuth instance) passed to Run() → invoked by gotd auth handler
- At auth.go:30 (Phone method): Calls prompt("Enter phone number...") at line 35
  - prompt() helper (auth.go:64-71) prints the message, creates bufio.Reader on os.Stdin (line 66), reads a line (line 67), and returns trimmed text (line 71)
  - Result cached in a.phone (line 40) and returned to gotd auth framework
- At auth.go:45 (Password method): Calls prompt("Enter 2FA password: ") at line 46
  - Same prompt() helper reads from stdin, trimmed result returned to gotd
  - Only invoked by gotd auth framework if the Telegram account has 2FA enabled
- At auth.go:50 (Code method): Calls prompt("Enter the code sent to your Telegram: ") at line 51
  - Same prompt() helper reads the OTP code from stdin, trimmed result returned to gotd
  - Invoked by gotd after Phone() succeeds, as the second step in phone-based auth sequence
- Output: User credentials (phone, OTP code, optional 2FA password) collected interactively and passed to gotd auth framework for MTProto authentication handshake

**Session Persistence Cycle (FileSessionStorage):**
- Input: `sessionFile string` parameter passed to NewClient() → stored in Client.session
- Transformation at client.go:39: Session file path wrapped into FileSessionStorage struct
- On Load (session.go:17): os.ReadFile() reads the file; json.Unmarshal() deserializes the blob into []byte; returns session.ErrNotFound if file is missing
- On Store (session.go:35): json.Marshal() encodes the []byte blob; os.WriteFile() writes to disk with 0600 permissions
- Output: MTProto session state persisted to disk, reloaded on next connection to restore authentication

**Authentication Flow (Run → authenticate):**
- Input: AuthFlow interface passed to Run() at client.go:33
- At client.go:54: If !status.Authorized, authenticate(ctx, auth) is called
- At client.go:69: auth.NewFlow(authFlow, auth.SendCodeOptions{}) wraps the AuthFlow interface
- Execution: c.client.Auth().IfNecessary(ctx, flow) invokes the gotd auth handler, which calls methods on the injected AuthFlow (e.g., Phone(), Code(), Password() from auth.go) to get credentials from the user
- Output: If authentication succeeds, session state is stored via FileSessionStorage.StoreSession(), and control returns to the caller's callback function f() at client.go:59

**Message Fetching and Filtering Flow (messages.go):**

6. **messages.go:44 FetchMessages() → messages.go:91 extractMessages() (call)**
   - FetchMessages() (line 44) calls api.MessagesGetHistory() at line 50 to fetch message history from a resolved InputChannel (ChannelID + AccessHash)
   - The API response is one of three types: MessagesMessages, MessagesMessagesSlice, or MessagesChannelMessages (lines 61-79)
   - For each response type, FetchMessages immediately calls extractMessages(h.Messages, debug) at lines 67, 73, and 79 to filter and transform the raw message slice
   - extractMessages() (defined at line 91) takes []tg.MessageClass and produces []Message by:
     - (1) Type-asserting each entry to filter only *tg.Message entries, discarding MessageEmpty and MessageService variants (lines 102-132)
     - (2) Filtering out *tg.Message entries with empty text (line 108)
     - (3) Converting each valid message to a simplified Message struct (lines 112-116): extracting ID (msg.ID), text (msg.Message), and timestamp (converting msg.Date to Unix time)
   - Returns []Message containing only messages with non-empty text content, normalized for downstream consumption

## Key Types (continued)

- **Message (messages.go:13-17)** — Simplified representation of a Telegram message. Fields: `ID int` (message ID), `Text string` (message content), `Timestamp time.Time` (message creation time). Created by extractMessages() from *tg.Message entries.

## Data Flow (continued)

**Message Fetching Pipeline (FetchMessages → extractMessages):**
- Input: *tg.InputChannel (resolved channel metadata: ChannelID + AccessHash), limit int (max message count), debug bool (verbose logging flag)
- API Call (messages.go:50): api.MessagesGetHistory() returns one of three response types, each containing a []tg.MessageClass slice
- Filtering (messages.go:91-140): extractMessages() type-filters to *tg.Message, discards empty text, converts to simplified Message struct
  - If debug flag is set, verbose printf output shows: response type and count (lines 65, 71, 77), per-message details (lines 98-106), filtering summary (line 136)
- Output: []Message with only messages containing text, ready for summarization or display

## Noted but Not Explored

**External Dependencies and Framework Integrations:**

- **client.go:33 Run → telegram.NewClient (github.com/gotd/td)** — SKIPPED: External gotd/td package call that creates the underlying Telegram MTProto client. Session storage is passed via Options struct for framework to manage persistence lifecycle.

- **client.go:68 authenticate → auth.NewFlow (github.com/gotd/td)** — SKIPPED: External gotd/td auth package that wraps UserAuthenticator into a phone/OTP/2FA flow handler.

- **client.go:68 authenticate → c.client.Auth().IfNecessary (github.com/gotd/td)** — SKIPPED: External gotd/td framework method that executes authentication if user is not already authorized.

- **auth.go:30,45,50 Phone/Password/Code → bufio.NewReader, reader.ReadString, fmt.Print, strings.TrimSpace** — SKIPPED: Standard library I/O (bufio, fmt, os, strings) for reading user input from terminal.

- **session.go:17 LoadSession → os.ReadFile, json.Unmarshal** — SKIPPED: Standard library file I/O and JSON deserialization for reading persisted MTProto session blob from disk.

- **session.go:35 StoreSession → json.Marshal, os.WriteFile** — SKIPPED: Standard library JSON serialization and file I/O for writing persisted MTProto session blob to disk with 0600 permissions.

- **messages.go:20 ResolveChannel → api.ContactsResolveUsername (github.com/gotd/td)** — SKIPPED: External gotd/td Telegram API call that resolves a channel @username into InputChannel metadata (ChannelID + AccessHash) via the Contacts service.

- **messages.go:44 FetchMessages → api.MessagesGetHistory (github.com/gotd/td)** — SKIPPED: External gotd/td Telegram API call that fetches message history from a channel with limit and offset pagination.

- **messages.go:20,44 ResolveChannel/FetchMessages → fmt.Errorf, strings.TrimPrefix** — SKIPPED: Standard library string formatting and manipulation (fmt for error wrapping, strings for @-prefix trimming).
