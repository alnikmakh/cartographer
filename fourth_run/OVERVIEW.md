# Explanation Map: tg-digest Telegram Client Package

## Entry Points

The `tg-digest/internal/telegram/` package exposes eight entry points for interacting with the Telegram API through the gotd/td MTProto framework:

1. **NewClient()** (client.go:23) — Constructs a Client wrapper that bundles API credentials and a session file path. No connection is established at this point; it simply creates an in-memory configuration object ready for use with Run().

2. **Run()** (client.go:33) — The primary entry point that orchestrates the full connection lifecycle. It establishes an MTProto connection to Telegram, initializes FileSessionStorage to handle session persistence, checks authentication status, triggers the authentication flow (via authenticate()) if the session is not yet authenticated, and then invokes the caller-supplied callback function to execute user code within the authenticated connection context.

3. **API()** (client.go:64) — Returns the underlying `*tg.Client` for making raw Telegram API calls. This is only safe to call from within the callback function passed to Run(), after the connection has been authenticated.

4. **NewTerminalAuth()** (auth.go:25) — Creates a TerminalAuth instance that implements the AuthFlow interface. This is the default interactive authentication method that prompts the user for phone number, OTP code, and 2FA password via stdin.

5. **FileSessionStorage.LoadSession()** (session.go:17) — Reads the MTProto session blob from disk, JSON-decodes it, and returns it. Returns `session.ErrNotFound` if the file is absent, signaling to gotd that a fresh authentication session should be initiated.

6. **FileSessionStorage.StoreSession()** (session.go:35) — JSON-encodes the MTProto session blob and persists it to disk with file mode 0600, enabling session resumption across application restarts.

7. **ResolveChannel()** (messages.go:20) — Resolves a Telegram channel @username to a `*tg.InputChannel` (containing ChannelID and AccessHash) via the Telegram Contacts API. Must be called from within a Run() callback after authentication.

8. **FetchMessages()** (messages.go:44) — Fetches up to `limit` recent messages from a resolved InputChannel via the Telegram Messages API and returns them as a normalized `[]Message` slice. Must be called from within a Run() callback after authentication.

## Call Chain

The package implements a three-phase workflow: **initialization → authentication → API operations**.

### Phase 1: Initialization

The caller creates a Client wrapper via **NewClient()** (client.go:23), which stores the API credentials and session file path. At this stage, no network I/O occurs; the Client is just a configuration container.

### Phase 2: Connection & Authentication

When the caller invokes **Run()** (client.go:33), several actions occur in sequence:

1. **Session Loading** (client.go:39–41): Run constructs a **FileSessionStorage** instance (session.go:11-14) with the Path field set to the session file path (c.session string from the NewClient argument). This FileSessionStorage is passed to gotd's telegram.NewClient() as the SessionStorage option. The gotd framework will call FileSessionStorage.LoadSession() (session.go:17) to attempt to restore a previous MTProto session from disk. If the file is absent, LoadSession returns `session.ErrNotFound`, and gotd treats the connection as fresh.

2. **Authentication Check** (client.go:45–60): Inside Run's callback, the code checks the authorization status via `c.client.Auth().Status()` (line 48). If not authorized (line 53), the **authenticate()** method is invoked (line 54).

3. **Authentication Execution** (client.go:54 → client.go:68): The **authenticate()** method (client.go:68-71) receives `context.Context` and an **AuthFlow** interface parameter (declared at client.go:33). It calls **auth.NewFlow()** to wrap the AuthFlow, then passes it to `c.client.Auth().IfNecessary()`, which executes the MTProto authentication sequence.

4. **Interactive Authentication** (auth.go:25 → auth.go:20): If the caller supplied **NewTerminalAuth()** (auth.go:25-27), a **TerminalAuth** struct instance is created. TerminalAuth (auth.go:20-22) implements the AuthFlow interface with the following methods:

   - **Phone()** (auth.go:30-42): Prompts for the phone number via the **prompt()** helper (line 35). The first call to Phone() reads from stdin, caches the result in `a.phone`, and returns it. Subsequent calls return the cached value.

   - **Code()** (auth.go:50-52): Prompts for the OTP code sent by Telegram, reading from stdin via **prompt()** (line 51). No caching occurs.

   - **Password()** (auth.go:45-47): Prompts for the 2FA password (if enabled on the account), reading from stdin via **prompt()** (line 46). No caching occurs.

   - **prompt()** (auth.go:64-72): A shared helper that reads a user message string from stdin using bufio.NewReader, trims whitespace with strings.TrimSpace, and returns the result.

   The authentication flow sequence is: Phone() → Telegram sends OTP → Code() → optionally Password() for 2FA. SignUp() is intentionally unsupported; the package expects an existing Telegram account.

5. **Session Persistence**: After successful authentication, gotd calls **FileSessionStorage.StoreSession()** (session.go:35) to JSON-encode and persist the session blob to the path specified in FileSessionStorage.Path, with file mode 0600.

### Phase 3: API Operations

Once Run's callback is executing and the client is authenticated, the caller can invoke **API operations** within the callback:

- **ResolveChannel()** (messages.go:20-42): Takes a `*tg.Client` (obtained via API(), line 64) and a channel username string. It calls the gotd Telegram Contacts API (`api.ContactsResolveUsername`) to resolve the username to a `*tg.InputChannel`, which contains the ChannelID and AccessHash needed for subsequent queries.

- **FetchMessages()** (messages.go:44-89): Takes a `*tg.Client`, a `*tg.InputChannel` (from ResolveChannel), and a limit parameter. It calls the gotd Telegram Messages API (`api.MessagesGetHistory`) to fetch message history. The response is one of three types: MessagesMessages, MessagesMessagesSlice, or MessagesChannelMessages. Each response type contains a `Messages []tg.MessageClass` field. FetchMessages dispatches the response to **extractMessages()** (lines 67, 73, 79).

- **extractMessages()** (messages.go:91-140): Normalizes the raw Telegram message slice into a simplified `[]Message` representation. It iterates through each entry in the input message slice and performs type assertions to identify concrete message types:
  - `*tg.Message`: The standard message type with actual text content.
  - `*tg.MessageEmpty`: Placeholder entries (silently discarded).
  - `*tg.MessageService`: Service messages like member joins (silently discarded).

  For each `*tg.Message` entry, the function checks if the `.Message` text field is non-empty (line 108); empty-text messages are discarded. For each valid message, a **Message** struct is constructed (lines 112-116) containing:
  - **ID** (msg.ID): The message identifier.
  - **Text** (msg.Message): The message text.
  - **Timestamp** (converted from msg.Date Unix timestamp): The message send time.

  The filtered and normalized `[]Message` is returned to FetchMessages' caller.

## Key Types

### Client (client.go, implicit struct)
- **Fields**:
  - `api *tg.Client` — The underlying gotd Telegram client.
  - `session string` — Path to the session persistence file.
  - `client *telegram.Client` — The gotd MTProto connection wrapper.
- **Usage**: Created by NewClient(), used by Run() and API().

### FileSessionStorage (session.go:11-14)
- **Fields**:
  - `Path string` — Filesystem path where the session blob is persisted.
- **Interface**: Implements gotd's `session.Storage` interface.
- **Methods**:
  - `LoadSession() ([]byte, error)` (line 17) — Reads and JSON-decodes the session blob from Path; returns `session.ErrNotFound` if the file is absent.
  - `StoreSession([]byte) error` (line 35) — JSON-encodes and writes the session blob to Path with mode 0600.

### AuthFlow (auth.go:15-16)
- **Interface**: Extends gotd's `auth.UserAuthenticator` interface.
- **Implementations**: TerminalAuth (auth.go:20-22) is the provided concrete implementation.
- **Methods** (inherited from UserAuthenticator):
  - `Phone(context.Context) (string, error)` — Returns the phone number.
  - `Code(context.Context, *tg.AuthSentCode) (string, error)` — Returns the OTP code.
  - `Password(context.Context) (string, error)` — Returns the 2FA password.
  - `SignUp(context.Context) (auth.Credentials, error)` — Not supported (intentionally).
  - `AcceptTermsOfService(context.Context, *tg.HelpTermsOfService) error` — Accepts ToS if needed.

### TerminalAuth (auth.go:20-22)
- **Fields**:
  - `phone string` — Cached phone number from the first Phone() call.
- **Implements**: AuthFlow interface.
- **Methods**:
  - `Phone()` (line 30) — Prompts for phone number, caches it, returns it on first call; returns cached value on subsequent calls.
  - `Code()` (line 50) — Prompts for OTP code via prompt(); no caching.
  - `Password()` (line 45) — Prompts for 2FA password via prompt(); no caching.
  - Other methods (SignUp, AcceptTermsOfService) have stub implementations.

### Message (messages.go, implicit struct)
- **Fields**:
  - `ID int` (line 113) — Telegram message identifier.
  - `Text string` (line 114) — Message text content.
  - `Timestamp time.Time` (line 115) — Message send timestamp (converted from msg.Date Unix seconds).
- **Usage**: Returned by FetchMessages as the normalized representation of Telegram messages.

### tg.InputChannel (external gotd/td type)
- **Origin**: `github.com/gotd/td/tg` package.
- **Role**: Identifies a Telegram channel for API operations. Contains ChannelID and AccessHash.
- **Produced by**: ResolveChannel() via the Contacts API.
- **Consumed by**: FetchMessages() as input to MessagesGetHistory.

### tg.Message, tg.MessageEmpty, tg.MessageService (external gotd/td types)
- **Origin**: `github.com/gotd/td/tg` package.
- **Role**: Concrete message types in the MessagesGetHistory API response.
- **Handling in extractMessages()**:
  - `*tg.Message` — Extracted if `.Message` text is non-empty; normalized to Message struct.
  - `*tg.MessageEmpty` — Silently discarded (placeholder entries).
  - `*tg.MessageService` — Silently discarded (non-text service messages like member joins).

## Data Flow

### End-to-End Session Lifecycle

1. **Input**: Caller creates NewClient() with API credentials and session file path.
2. **Storage initialization**: Run() constructs FileSessionStorage with the path.
3. **Session loading**: gotd calls FileSessionStorage.LoadSession() to attempt recovery of a persisted session.
4. **Authentication (if needed)**: If LoadSession failed or the session is not authenticated:
   - Run's callback calls authenticate(), which invokes auth.NewFlow() with the caller's AuthFlow implementation (e.g., TerminalAuth).
   - TerminalAuth prompts the user for phone, OTP code, and optional 2FA password via prompt(), reading from stdin.
   - gotd executes the MTProto authentication sequence: Phone() → OTP delivery → Code() → optional Password().
   - Upon success, gotd calls FileSessionStorage.StoreSession() to persist the session blob.
5. **Output**: The authenticated `*tg.Client` is available to the Run() callback via API().

### End-to-End Message Fetching

1. **Input**: Caller supplies a channel username string and message limit to the Run() callback.
2. **Channel resolution**: ResolveChannel() calls gotd's ContactsResolveUsername API to resolve the username to a `*tg.InputChannel` (containing ChannelID and AccessHash).
3. **Message fetch**: FetchMessages() calls gotd's MessagesGetHistory API with the InputChannel and limit.
4. **Response handling**: The API response (one of MessagesMessages, MessagesMessagesSlice, MessagesChannelMessages) contains a `[]tg.MessageClass` slice.
5. **Normalization**: extractMessages() iterates the slice, filters by message type (discards MessageEmpty and MessageService), filters by content (discards *tg.Message with empty .Message text), and constructs a `[]Message` struct with ID, Text, and Timestamp.
6. **Output**: FetchMessages() returns the filtered `[]Message` to the caller.

### Data Transformations

- **Session blob**: Byte slice (binary MTProto session state) ↔ FileSessionStorage.Path (JSON-encoded on disk).
- **Phone number**: stdin input string → cached in TerminalAuth.phone → passed to gotd's auth flow.
- **OTP code**: stdin input string → passed to gotd's auth verification.
- **2FA password**: stdin input string → passed to gotd's 2FA verification.
- **Channel username**: String (@name) → ContactsResolveUsername API → `*tg.InputChannel` (ChannelID + AccessHash).
- **Message history**: MessagesGetHistory API response → extractMessages type dispatch → filtered message slice → `[]Message` with normalized fields (ID, Text, Timestamp).

## Noted but Not Explored

The following edges are at the package boundary and were not explored in detail:

- **messages.go:23 ResolveChannel → api.ContactsResolveUsername** — SKIPPED: Direct call to the Telegram Contacts API in the gotd/td SDK (`github.com/gotd/td/tg`). This API resolves a @username to a channel/chat identifier with access hash. It is external to the tg-digest codebase and its internal implementation is outside the scope of this exploration.

- **messages.go:50 FetchMessages → api.MessagesGetHistory** — SKIPPED: Direct call to the Telegram Messages API in the gotd/td SDK (`github.com/gotd/td/tg`). This API fetches channel message history with a limit parameter and returns a paginated response (MessagesMessages, MessagesMessagesSlice, or MessagesChannelMessages variants). It is external to the tg-digest codebase and its internal implementation is outside the scope of this exploration.
