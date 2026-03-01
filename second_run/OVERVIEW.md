# Explanation Map

## Entry Points

- **client.go:23 NewClient()** - Constructs a Client wrapper with API credentials (apiID, apiHash) and session file path. No network connection is made at this point; the struct merely stores configuration for later use by Run().

- **client.go:33 Run()** - The main entry point for connecting to Telegram. Establishes the MTProto connection via gotd/td, initializes session persistence, checks authentication status, triggers authenticate() if the user is not already logged in, then executes the caller-supplied callback function f() inside the MTProto connection context.

- **auth.go:25 NewTerminalAuth()** - Creates a TerminalAuth instance that satisfies the AuthFlow interface. This is the concrete implementation that prompts users interactively for phone number, OTP code, and 2FA password.

- **session.go:17 FileSessionStorage.LoadSession()** - Reads and JSON-decodes the MTProto session blob from disk. Returns session.ErrNotFound when the file is absent, signaling to gotd/td that this is a fresh session requiring full authentication.

- **messages.go:20 ResolveChannel()** - Resolves a channel @username to a *tg.InputChannel (ChannelID + AccessHash) via the Telegram ContactsResolveUsername API call.

- **messages.go:44 FetchMessages()** - Fetches up to `limit` recent messages from a resolved InputChannel via the Telegram MessagesGetHistory API call.

## Call Chain

**Run() → authenticate() (client.go:33 → client.go:68)**

At line 54, Run() calls c.authenticate(ctx, auth) when the user is not already authenticated (!status.Authorized). The authenticate() function wraps the supplied authFlow parameter with gotd/td's auth.NewFlow() constructor (line 69) and calls c.client.Auth().IfNecessary(ctx, flow) (line 70) to orchestrate the full MTProto phone authentication sequence. The gotd/td framework then invokes methods on authFlow (Phone, Code, Password, optionally SignUp) as needed. The function returns an error indicating whether authentication succeeded or failed. This edge is critical to the flow because it gates entry into the authenticated context—no Telegram API calls are possible until Run() completes, and if authentication is required, it must succeed.

**Run() → FileSessionStorage (client.go:33 → session.go:12)**

At line 39, Run() instantiates a FileSessionStorage struct initialized with c.session (the session file path supplied during NewClient construction). This instance is passed to telegram.NewClient at line 42 as the SessionStorage option in telegram.Options{}. The FileSessionStorage type implements gotd/td's session.Storage interface, which the gotd/td framework uses to load and persist the MTProto session blob. On subsequent runs, the same session is restored from disk, avoiding the need for re-authentication. This edge is critical because it enables session persistence across process restarts.

## Key Types

**Client struct (client.go:14-20)**
A wrapper around the gotd/td telegram.Client. Stores apiID, apiHash, session file path, and references to the underlying gotd/td client and its API. The Run() method is the primary public interface.

**FileSessionStorage struct (session.go:12-14)**
A simple struct holding only a Path field. Implements gotd/td's session.Storage interface with LoadSession() (line 17) and StoreSession() (line 35) methods. LoadSession() reads and JSON-decodes the session blob from disk; StoreSession() JSON-encodes and writes the blob with file mode 0600.

**AuthFlow interface (auth.go, implicitly)**
An interface that must provide Phone(ctx), Code(ctx, codeHash), Password(ctx), and SignUp(ctx) methods. TerminalAuth (auth.go:25) is the concrete implementation that prompts users via stdout/stdin. The interface is abstract in this file and is defined in the gotd/td framework.

## Data Flow

**Session Persistence Flow:**
FileSessionStorage is instantiated in Run() with the session file path → passed to telegram.NewClient → gotd/td calls LoadSession() on startup (returns []byte MTProto session blob from disk, or session.ErrNotFound if absent) → after successful authentication, gotd/td calls StoreSession(ctx, blob) to persist the session → on next Run() call, the same blob is loaded and reused, avoiding re-authentication.

**Authentication Flow:**
Run() checks c.client.Auth().Status() (line 48) → if !status.Authorized, calls authenticate(ctx, authFlow) (line 54) → authenticate() wraps authFlow with auth.NewFlow() and calls c.client.Auth().IfNecessary() → gotd/td orchestrates the phone auth sequence, invoking authFlow.Phone(), then authFlow.Code(), optionally authFlow.Password() → prompts are handled by the concrete AuthFlow implementation (TerminalAuth uses fmt.Print + bufio for stdout/stdin I/O) → on success, the MTProto session is authenticated and ready for API calls.

**Phone() → prompt() (auth.go:30 → auth.go:64)**

At line 35, the TerminalAuth.Phone() method calls prompt() with the message "Enter phone number (with country code, e.g., +1234567890): ". The prompt() function (defined at line 64) writes the message to stdout via fmt.Print(), creates a buffered reader on os.Stdin via bufio.NewReader(), reads a line of text until the newline character via reader.ReadString('\n'), trims whitespace, and returns the result as a string along with any error. Phone() caches the result in the a.phone field (line 40) to avoid redundant prompts if the method is called multiple times. The returned string and error are propagated up to gotd/td's auth orchestration. This edge is critical because it is the first step in the phone authentication sequence; the user's phone number must be collected and sent to Telegram to initiate the OTP delivery flow.

**Password() → prompt() (auth.go:45 → auth.go:64)**

At line 46, the TerminalAuth.Password() method directly returns the result of calling prompt() with the message "Enter 2FA password: ". The prompt() function performs the same I/O sequence: write message to stdout, read user input, trim whitespace, return (string, error). No caching is performed for the password. The returned string and error are propagated to gotd/td's auth orchestration. This edge is conditional; Password() is only invoked by gotd/td if the user's account has two-factor authentication enabled. It comes after the OTP code has been verified, as the final step in the authentication sequence.

**Code() → prompt() (auth.go:50 → auth.go:64)**

At line 51, the TerminalAuth.Code() method calls prompt() with the message "Enter the code sent to your Telegram: ". The code parameter (line 50) is a *tg.AuthSentCode context from gotd/td containing metadata about the OTP delivery method, but it is explicitly unused (unnamed parameter) in the current implementation. The prompt() function executes its standard sequence: write message, read input, trim whitespace, return (string, error). The returned string is the one-time password sent by Telegram to the user's phone. This edge is critical in the phone auth sequence because it collects the OTP that proves the user owns the phone number. Code() is invoked after Phone() and before the optional Password().

**prompt() Implementation (auth.go:64-71)**

The prompt() function is a helper that implements interactive terminal I/O. It takes a message string, writes it to stdout using fmt.Print() (line 65), creates a buffered reader on os.Stdin (line 66), reads text until newline using reader.ReadString('\n') (line 67), trims surrounding whitespace using strings.TrimSpace() (line 71), and returns the cleaned string or an error if reading fails. This function is called by all three authentication methods (Phone, Password, Code) and is the singular point where user input is collected during the authentication flow.

**FetchMessages() → extractMessages() (messages.go:44 → messages.go:91)**

At lines 67, 73, and 79, FetchMessages() calls extractMessages() with a []tg.MessageClass slice and a debug bool flag. These calls occur within switch cases that handle three different Telegram API response types (MessagesMessages, MessagesMessagesSlice, and MessagesChannelMessages). The extractMessages() function iterates through the raw message objects (line 97), filters and transforms them into simplified Message structs. It skips messages with empty text (lines 108-111), discards MessageEmpty and MessageService system messages (lines 117-126), and converts valid *tg.Message objects into Application Message structs by extracting ID, Message text, and Date fields (lines 112-116, converting the Unix seconds timestamp via time.Unix() at line 115). The function returns a []Message slice containing only messages with actual text content. This edge is critical to the message retrieval pipeline: FetchMessages() orchestrates the raw API call to retrieve messages from a channel (line 50, api.MessagesGetHistory()), and extractMessages() immediately filters and normalizes the raw API response into the application's simplified Message format, removing system messages and empty messages that are not useful for the digest feature.

## Noted but Not Explored

- client.go:41 Run → telegram.NewClient — SKIPPED: Constructs the underlying gotd/td Telegram client with session storage configuration and API credentials (apiID, apiHash); this is the external MTProto connection setup managed entirely by the gotd/td framework (github.com/gotd/td)
- client.go:45 Run → c.client.Run — SKIPPED: External gotd/td method that manages the MTProto connection lifecycle, executes the caller-supplied callback function, and handles authentication checks; the connection and session persistence are managed by gotd/td
- client.go:46 Run → c.client.API() — SKIPPED: External gotd/td method that returns the underlying *tg.Client for making raw Telegram API calls; only accessible after the MTProto connection is established
- client.go:48 Run → c.client.Auth().Status() — SKIPPED: External gotd/td method that checks current authentication status of the MTProto session without triggering new authentication flow
- client.go:69 authenticate → auth.NewFlow() — SKIPPED: External gotd/td API that wraps the provided AuthFlow interface and orchestrates the MTProto phone authentication sequence (phone prompt → OTP code → optional 2FA password); delegates actual prompts to the authFlow parameter
- auth.go:56 SignUp → fmt.Errorf() — SKIPPED: Constructs error message indicating sign-up is unsupported; fallback path for account provisioning that is explicitly disabled in this implementation
- auth.go:65 prompt → fmt.Print() — SKIPPED: Standard library function that writes prompt string to stdout
- auth.go:66 prompt → bufio.NewReader() — SKIPPED: Standard library function that creates a buffered reader for terminal stdin
- auth.go:67 prompt → reader.ReadString() — SKIPPED: Standard library function that reads user input from stdin until newline
