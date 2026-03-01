# Edge Queue

## Relevant Edges

FORMAT: - [ ] [dN] source_file:line function → target_file:line function — edge_type
PROVEN: - [x] [dN] (same) — SUMMARY: what goes in, what happens, what comes out

edge_type: call | DI | event | config | middleware | re-export

- [x] [d1] client.go:33 Run → client.go:68 authenticate — call — SUMMARY: AuthFlow parameter passed to authenticate (line 54), converted to auth.NewFlow for authentication
- [x] [d1] messages.go:44 FetchMessages → messages.go:91 extractMessages — call — SUMMARY: Raw tg.MessageClass slice from API history (MessagesGetHistory) filtered by extractMessages to extract only non-empty *tg.Message entries and convert to []Message with ID, Text, Timestamp
- [x] [d1] auth.go:30 Phone → auth.go:64 prompt — call — SUMMARY: Phone method (line 35) calls prompt with "Enter phone number" message, returns string input from user
- [x] [d1] auth.go:45 Password → auth.go:64 prompt — call — SUMMARY: Password method (line 46) calls prompt with "Enter 2FA password" message, returns string input from user
- [x] [d1] auth.go:50 Code → auth.go:64 prompt — call — SUMMARY: Code method (line 51) calls prompt with "Enter the code sent to your Telegram" message, returns string input from user


## Irrelevant Edges (noted, not explored)

FORMAT: - source_file:line function → target — SKIPPED: reason

- client.go:68 authenticate → auth.NewFlow — SKIPPED: external gotd/td package
- client.go:68 authenticate → c.client.Auth().IfNecessary — SKIPPED: external gotd/td package
- messages.go:20 ResolveChannel → api.ContactsResolveUsername — SKIPPED: external gotd/td API
- messages.go:44 FetchMessages → api.MessagesGetHistory — SKIPPED: external gotd/td API
