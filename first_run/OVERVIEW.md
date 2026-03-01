# Explanation Map

## Entry Points

(filled by agent from CONTEXT.md on first iteration)

## Call Chain

- `client.go:33 Run()` → `client.go:68 authenticate()`: Calls authenticate with AuthFlow parameter at line 54 to perform authentication when not already authorized
- `auth.go:30 Phone()` → `auth.go:64 prompt()`: Prompts user for phone number (with country code) at line 35, returns trimmed user input from stdin
- `auth.go:45 Password()` → `auth.go:64 prompt()`: Prompts user for 2FA password at line 46, returns trimmed user input from stdin
- `auth.go:50 Code()` → `auth.go:64 prompt()`: Prompts user for authentication code sent to Telegram at line 51, returns trimmed user input from stdin

## Key Types

(agent appends type definitions encountered during proving)

## Data Flow

- `messages.go:44 FetchMessages()` → `messages.go:91 extractMessages()`: Raw tg.MessageClass slice from API response (MessagesGetHistory result) filtered to non-empty *tg.Message entries and converted to []Message with ID, Text, Timestamp fields

## Noted but Not Explored

(agent copies irrelevant edges here with explanations from QUEUE.md)
