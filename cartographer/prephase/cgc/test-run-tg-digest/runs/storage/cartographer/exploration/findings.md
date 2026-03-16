---
scope: internal/storage/storage.go
files_explored: 11
boundary_packages: 1
generated: TIMESTAMP
---

## Purpose

The `storage` package is the persistence layer for tg-digest. It provides every other package in the application — refresh, summarizer, TUI — with a single `Store` interface to create, query, and manage channels, messages, per-message summaries, and sync state. Seven packages make 62+ inbound calls to it; understanding this interface is prerequisite for understanding the rest of the codebase.

## Architecture

**Dependency diagram**

```
  storage.go ─── defines ───→ Store interface
    │                          ChannelRepository
    │                          MessageRepository
    │                          MessageSummaryRepository
    │                          SyncStateRepository
    │                          Domain types (Channel, Message, MessageSummary, SyncState)
    │
    ├── Open() calls ──→ migrations.go ──→ migrations/*.sql (embedded)
    │
    ├── delegates to ──→ channels.go          (implements ChannelRepository)
    ├── delegates to ──→ messages.go          (implements MessageRepository)
    ├── delegates to ──→ message_summaries.go (implements MessageSummaryRepository)
    └── delegates to ──→ syncstate.go         (implements SyncStateRepository)
                              │
                              └── all use ──→ [modernc.org/sqlite]†

  storage_test.go ── tests ──→ all of the above via Store interface

  † boundary: pure-Go SQLite driver, imported as blank identifier for side-effect registration
```

**Key interfaces and signatures**

```go
// Entry point — the only constructor callers need
func Open(ctx context.Context, dbPath string) (Store, error)

type Store interface {
    Channels()        ChannelRepository
    Messages()        MessageRepository
    MessageSummaries() MessageSummaryRepository
    SyncState()       SyncStateRepository
    Close() error
}

type ChannelRepository interface {
    Create(ctx context.Context, channel *Channel) error
    CreateNonTelegram(ctx context.Context, channel *Channel) error
    GetByID(ctx context.Context, id int64) (*Channel, error)
    GetByTelegramID(ctx context.Context, telegramID int64) (*Channel, error)
    GetByUsername(ctx context.Context, username string) (*Channel, error)
    List(ctx context.Context) ([]*Channel, error)
    Delete(ctx context.Context, id int64) error
}

type MessageRepository interface {
    Create(ctx context.Context, message *Message) error
    GetByChannelAndDate(ctx context.Context, channelID int64, start, end time.Time) ([]*Message, error)
    GetLatestByChannel(ctx context.Context, channelID int64, limit int) ([]*Message, error)
    CountByChannel(ctx context.Context, channelID int64, start, end time.Time) (int, error)
    GetDistinctDates(ctx context.Context, channelID int64) ([]time.Time, error)
}

type MessageSummaryRepository interface {
    Create(ctx context.Context, ms *MessageSummary) error
    GetByMessageID(ctx context.Context, messageID int64) (*MessageSummary, error)
    GetByChannelAndDate(ctx context.Context, channelID int64, start, end time.Time) ([]*MessageSummary, error)
    GetUnsummarizedMessages(ctx context.Context, start, end time.Time) ([]*Message, error)
    GetUnsummarizedMessagesByChannels(ctx context.Context, start, end time.Time, channelIDs []int64) ([]*Message, error)
}

type SyncStateRepository interface {
    Get(ctx context.Context, channelID int64) (*SyncState, error)
    Upsert(ctx context.Context, state *SyncState) error
}
```

**Domain types**

```go
type Channel struct {
    ID, TelegramID int64; Title, Username, SourceType string; AddedAt time.Time
}
type Message struct {
    ID, ChannelID int64; TelegramMsgID int; Text string; SentAt, FetchedAt time.Time
}
type MessageSummary struct {
    ID, MessageID int64; Summary, Model string; CreatedAt time.Time
}
type SyncState struct {
    ChannelID int64; Checkpoint string; LastSyncAt time.Time
}
```

**Pattern identification**

- **Repository pattern** — each domain entity has a dedicated repository interface with its own implementation struct (`channelRepo`, `messageRepo`, etc.), all hiding SQL behind method contracts.
- **Facade** — `Store` acts as a facade, exposing four repository accessors from a single `Open()` call. Callers never construct repositories directly.
- **Embedded migrations** — `//go:embed` compiles SQL files into the binary; `runMigrations` applies them idempotently at startup. This is a self-migrating database pattern.

## Data Flow

**Flow 1: Store initialization**

1. Caller invokes `Open(ctx, dbPath)` — `storage.go:106`
2. `expandPath()` resolves `~` in dbPath — `storage.go:108`
3. `os.MkdirAll` ensures the directory exists — `storage.go:111`
4. `sql.Open("sqlite", dbPath)` opens the database — `storage.go:116`
5. `db.SetMaxOpenConns(1)` constrains to single connection — `storage.go:122`
6. `runMigrations(ctx, db)` — `migrations.go:15`: creates `migrations` tracking table, reads embedded `.sql` files sorted alphabetically, for each unapplied migration wraps execution + recording in a transaction
7. Four repository structs are instantiated with the shared `*sql.DB` — `storage.go:130-134`
8. `Store` is returned to the caller

**Flow 2: Creating a message (with deduplication)**

1. Caller invokes `store.Messages().Create(ctx, &Message{...})`
2. `messageRepo.Create` executes `INSERT ... ON CONFLICT(channel_id, telegram_msg_id) DO NOTHING RETURNING id, fetched_at` — `messages.go:18-23`
3. If the message already exists, `RETURNING` produces no rows → `sql.ErrNoRows` → method returns `nil` (silent dedup) — `messages.go:32-35`
4. If new, `message.ID` and `message.FetchedAt` are populated via `Scan` — `messages.go:30`

**Flow 3: Finding unsummarized messages for specific channels**

1. Caller invokes `store.MessageSummaries().GetUnsummarizedMessagesByChannels(ctx, start, end, channelIDs)`
2. If `channelIDs` is nil/empty, delegates to `GetUnsummarizedMessages` (no channel filter) — `message_summaries.go:137-139`
3. Otherwise, builds dynamic SQL with `strings.Join` for the `IN (?)` clause — `message_summaries.go:141-155`
4. LEFT JOIN `messages` ↔ `message_summaries` with `WHERE ms.id IS NULL` finds gaps — `message_summaries.go:149-152`
5. Returns `[]*Message` ordered by `sent_at ASC`

## Boundaries

| Boundary | Role | Used By | Key Types |
|----------|------|---------|-----------|
| `modernc.org/sqlite` | Pure-Go SQLite driver (registered via blank import) | `storage.go` | `database/sql` standard interfaces |

No other boundary packages were declared or observed. The package's own interface (`Store` and its repositories) serves as the boundary consumed by 7 upstream packages (`refresh`, `summarizer`, `tui`, and their tests).

## Non-Obvious Behaviors

- **Message deduplication is silent.** `messageRepo.Create` uses `ON CONFLICT DO NOTHING` with `RETURNING`. When a duplicate `(channel_id, telegram_msg_id)` is inserted, no row is returned, `Scan` gets `sql.ErrNoRows`, and the method returns `nil` — no error, no indication to the caller that the message was a duplicate. The `message.ID` and `message.FetchedAt` fields remain zero. (`messages.go:21-35`)

- **Summary Create is actually an upsert.** Despite the name `Create`, `messageSummaryRepo.Create` uses `ON CONFLICT(message_id) DO UPDATE SET summary, model, created_at`. Re-summarizing a message overwrites the previous summary in place, preserving the original row ID. (`message_summaries.go:21-24`, confirmed by `TestMessageSummary_CreateUpsert` at `storage_test.go:204`)

- **Not-found returns nil, not error.** `GetByID`, `GetByTelegramID`, `GetByUsername`, `GetByMessageID`, and `SyncState.Get` all return `(nil, nil)` when no row is found — not `sql.ErrNoRows`. Callers must nil-check the result, not the error. (`channels.go:94-96`, `syncstate.go:28-29`, `message_summaries.go:58-59`)

- **Channel.Create auto-defaults SourceType.** `channelRepo.Create` defaults `SourceType` to `"telegram"` if empty (`channels.go:36-38`). `CreateNonTelegram` defaults to `"rss"` (`channels.go:63`). Both are set in Go code before the INSERT, not via database defaults.

- **Single-connection pool.** `db.SetMaxOpenConns(1)` at `storage.go:122` means all repository operations serialize through one connection. This prevents SQLite locking issues but means concurrent callers queue.

- **GetDistinctDates uses SUBSTR, not DATE().** `messages.go:111` extracts dates via `SUBSTR(sent_at, 1, 10)` because SQLite's `DATE()` function may not parse Go's `time.Time` format correctly. Unparseable date strings are silently skipped (`messages.go:132`).

- **Channel List is ordered by added_at DESC** — newest channels first. (`channels.go:148`)

- **Channel Delete fails with an error (not nil) if the channel doesn't exist.** It checks `RowsAffected` and returns `fmt.Errorf("channel not found")` — a non-wrapped, non-sentinel error. (`channels.go:186-188`)

- **expandPath only handles `~/` prefix**, not `~user/` paths. (`storage.go:169`)

- **Migration 004 drops the legacy `summaries` table** (daily aggregates per channel) and replaces it with `message_summaries` (per-message). This is a destructive, irreversible migration — there is no data migration from old summaries to new.

## Test Coverage Shape

The test file (`storage_test.go`) contains 10 test functions exercising the `Store` interface through real SQLite databases in temp directories — these are integration tests, not mocked.

**Well-covered:**
- Channel source type defaulting (telegram and rss)
- SyncState upsert with string checkpoints
- MessageSummary full CRUD: create, get by ID, get by channel+date range, upsert semantics
- Unsummarized message queries: all-channels (nil filter), specific channel IDs, exclusion of already-summarized messages

**Conspicuously absent:**
- No tests for `MessageRepository` directly (Create deduplication, GetByChannelAndDate, GetLatestByChannel, GetDistinctDates, CountByChannel) — these are only exercised indirectly through `seedChannelAndMessages`
- No tests for `ChannelRepository.Delete`, `GetByTelegramID`, `GetByUsername`, or `List`
- No tests for `CreateNonTelegram` with NULL telegram_id
- No tests for migration failure/rollback behavior
- No tests for `expandPath` or `Open` with invalid paths
- No tests for concurrent access behavior under the single-connection constraint

Tests verify behavior (query results, upsert semantics) rather than implementation details. The `seedChannelAndMessages` helper establishes the pattern of creating realistic test fixtures with time offsets.
