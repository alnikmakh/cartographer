# Scout Context

## Entry Points

- tg-digest/internal/storage/storage.go:106 — Open() opens the SQLite database, runs migrations, wires all repositories into a Store
- tg-digest/internal/storage/channels.go:35 — channelRepo.Create() inserts a new Telegram channel row, populates ID and AddedAt via RETURNING
- tg-digest/internal/storage/channels.go:61 — channelRepo.CreateNonTelegram() inserts a channel with NULL telegram_id (e.g. RSS sources)
- tg-digest/internal/storage/channels.go:86 — channelRepo.GetByID() looks up a channel by its database primary key
- tg-digest/internal/storage/channels.go:105 — channelRepo.GetByTelegramID() looks up a channel by its Telegram numeric ID
- tg-digest/internal/storage/channels.go:124 — channelRepo.GetByUsername() looks up a channel by its @username string
- tg-digest/internal/storage/channels.go:143 — channelRepo.List() returns all channels ordered by added_at DESC
- tg-digest/internal/storage/channels.go:173 — channelRepo.Delete() removes a channel by ID, errors if not found
- tg-digest/internal/storage/messages.go:17 — messageRepo.Create() inserts a message with ON CONFLICT DO NOTHING for deduplication
- tg-digest/internal/storage/messages.go:44 — messageRepo.GetByChannelAndDate() fetches messages for a channel within a sent_at range
- tg-digest/internal/storage/messages.go:75 — messageRepo.GetLatestByChannel() fetches the N most recent messages for a channel
- tg-digest/internal/storage/messages.go:107 — messageRepo.GetDistinctDates() returns distinct UTC dates that have messages for a channel
- tg-digest/internal/storage/messages.go:144 — messageRepo.CountByChannel() counts messages for a channel within a date range
- tg-digest/internal/storage/message_summaries.go:17 — messageSummaryRepo.Create() upserts a per-message summary (ON CONFLICT update)
- tg-digest/internal/storage/message_summaries.go:42 — messageSummaryRepo.GetByMessageID() retrieves one summary by its parent message ID
- tg-digest/internal/storage/message_summaries.go:69 — messageSummaryRepo.GetByChannelAndDate() retrieves summaries joined to messages by channel and date range
- tg-digest/internal/storage/message_summaries.go:101 — messageSummaryRepo.GetUnsummarizedMessages() returns messages with no summary row in the date range
- tg-digest/internal/storage/message_summaries.go:136 — messageSummaryRepo.GetUnsummarizedMessagesByChannels() same as above but filtered to specific channel IDs
- tg-digest/internal/storage/syncstate.go:14 — syncStateRepo.Get() retrieves the checkpoint and last-sync timestamp for a channel
- tg-digest/internal/storage/syncstate.go:39 — syncStateRepo.Upsert() inserts or updates the sync state for a channel
- tg-digest/internal/storage/migrations.go:15 — runMigrations() bootstraps the migrations table and applies any unapplied SQL files in order

## Boundaries

Explore within:
- tg-digest/internal/storage/
- tg-digest/internal/storage/migrations/

Do NOT explore:
- tg-digest/internal/tui/
- tg-digest/internal/telegram/
- tg-digest/internal/source/
- tg-digest/internal/summarizer/
- tg-digest/internal/refresh/
- tg-digest/internal/config/
- tg-digest/cmd/
- Any file ending in _test.go

## Max Depth

5 hops from any entry point.

## Notes

- SQLite driver is modernc.org/sqlite — pure Go, no CGO required; registered under the driver name "sqlite".
- The store uses a single database connection (MaxOpenConns=1) to avoid SQLite locking issues.
- All four repositories (channelRepo, messageRepo, messageSummaryRepo, syncStateRepo) are created inside Open() and held on sqliteStore; callers access them via the Store interface accessor methods (Channels(), Messages(), MessageSummaries(), SyncState()).
- Message deduplication is handled entirely at the database level via a UNIQUE constraint on (channel_id, telegram_msg_id); Create() uses ON CONFLICT DO NOTHING and treats sql.ErrNoRows on the RETURNING scan as a success.
- MessageSummary upsert uses ON CONFLICT(message_id) DO UPDATE, so re-summarizing a message overwrites the existing row.
- SyncState is keyed by channel_id with ON CONFLICT DO UPDATE, giving each channel exactly one checkpoint string that records the last Telegram message ID (or equivalent cursor) seen during sync.
- SQL migrations are embedded into the binary via //go:embed migrations/*.sql and applied in lexicographic filename order (001_initial.sql through 004_message_summaries.sql). Applied migration names are tracked in a migrations table to ensure idempotency. Each migration runs inside its own transaction.
- The four migration files define: initial schema (001), source_type column (002), nullable telegram_id (003), message_summaries table (004).
