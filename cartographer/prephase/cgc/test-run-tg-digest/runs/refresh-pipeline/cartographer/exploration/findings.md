---
scope: internal/refresh/refresh.go
files_explored: 3
boundary_packages: 3
generated: TIMESTAMP
---

## Purpose

The `refresh` package is the ingestion orchestrator for tg-digest. It pulls new messages from two kinds of sources — Telegram channels (via the gotd/td API) and generic feeds (RSS, Reddit, HackerNews) — deduplicates them, stores them in the database, and advances per-channel sync checkpoints so subsequent refreshes are incremental. Callers (the CLI entrypoint and TUI) use `Service` as the single interface for "go get new content."

## Architecture

**Dependency diagram**

```
                  refresh.go
                  ┌────────────────────────┐
                  │  Service               │
                  │  - RefreshAll()        ←──── Telegram path
                  │  - RefreshAllSources() ←──── Generic source path
                  │  - RefreshSources()    │
                  │  - RefreshFiltered()   │
                  └────┬──────┬──────┬─────┘
                       │      │      │
          implements   │      │      │  uses
          Fetcher      │      │      │
     ┌─────────────────┘      │      └──────────────────┐
     ▼                        ▼                          ▼
telegram.go            [storage]†               [source]†
┌──────────────────┐   Store interface          Source interface
│ TelegramFetcher  │   .Channels()              + Registry
│ - FetchNewMsgs() │   .Messages()
│ - extractMsgs()  │   .SyncState()
└────────┬─────────┘
         │ uses
         ▼
  [gotd/td/tg]†
  Telegram API SDK

† boundary packages
```

**Key interfaces and signatures**

```go
// Fetcher — abstraction over Telegram message retrieval
type Fetcher interface {
    FetchNewMessages(ctx context.Context, username string, afterMsgID int, limit int) ([]FetchedMessage, error)
}

// Value types
type FetchedMessage struct {
    TelegramMsgID int
    Text          string
    SentAt        time.Time
}

type RefreshResult struct {
    ChannelsRefreshed int
    NewMessages       int
    Errors            []error
}

// Service — the orchestrator
func NewService(fetcher Fetcher, store storage.Store, limit int) *Service
func (s *Service) RefreshAll(ctx context.Context) (*RefreshResult, error)
func (s *Service) RefreshFiltered(ctx context.Context, sourceNames []string) (*RefreshResult, error)
func (s *Service) RefreshSources(ctx context.Context, sources []source.Source) (*RefreshResult, error)
func (s *Service) RefreshAllSources(ctx context.Context, registry *source.Registry) (*RefreshResult, error)

// TelegramFetcher — Fetcher implementation
func NewTelegramFetcher(api *tg.Client) *TelegramFetcher
func (f *TelegramFetcher) FetchNewMessages(ctx context.Context, username string, afterMsgID int, limit int) ([]FetchedMessage, error)
```

**Pattern identification**

- **Adapter pattern** — `TelegramFetcher` adapts the gotd/td `tg.Client` into the `Fetcher` interface. The generic `source.Source` interface serves the same role for RSS/Reddit/HN.
- **Strategy pattern** — Two fetch strategies share the same store-and-checkpoint logic but differ in how they obtain messages: `RefreshAll` uses `Fetcher` (Telegram-specific, integer message ID checkpoints), `RefreshSources` uses `source.Source` (string checkpoints, source-provided).
- **Registry pattern** — `source.Registry` collects heterogeneous `Source` implementations; `RefreshAllSources` iterates the registry list.

## Data Flow

**Flow 1: Telegram channel refresh (`RefreshAll`)**

1. `Service.RefreshAll` calls `store.Channels().List(ctx)` to get all monitored channels
2. For each channel, calls `store.SyncState().Get(ctx, ch.ID)` — parses `Checkpoint` string as integer `afterMsgID`
3. Calls `fetcher.FetchNewMessages(ctx, ch.Username, afterMsgID, s.limit)`
4. `TelegramFetcher.FetchNewMessages` strips `@` prefix, calls `api.ContactsResolveUsername` to get channel ID + access hash
5. Builds `MessagesGetHistoryRequest` with `Limit` and (if incremental) `MinID = afterMsgID`; calls `api.MessagesGetHistory`
6. `extractMessages` type-switches on response (`MessagesMessages` / `MessagesMessagesSlice` / `MessagesChannelMessages`), filters to `*tg.Message` with non-empty `.Message` field, converts to `[]FetchedMessage`
7. Back in `RefreshAll`: iterates messages, calls `store.Messages().Create` for each — UNIQUE constraint silently deduplicates
8. Finds max `TelegramMsgID` across fetched messages, calls `store.SyncState().Upsert` with that as the new checkpoint
9. Returns `RefreshResult` with counts and accumulated errors

**Flow 2: Generic source refresh (`RefreshAllSources`)**

1. `RefreshAllSources` calls `registry.List()`, delegates to `RefreshSources`
2. For each source, calls `store.Channels().GetByUsername(ctx, src.Name())` — if no matching channel exists, silently skips
3. Loads checkpoint from `store.SyncState().Get`
4. Calls `src.FetchMessages(ctx, checkpoint, s.limit)` — source returns messages + new checkpoint string
5. For each message: converts `ExternalID` to int via `strconv.Atoi`; if that fails, falls back to `crc32.ChecksumIEEE` of the ID string to produce a numeric `TelegramMsgID`
6. Calls `store.Messages().Create` per message (UNIQUE constraint dedup), counts only successful inserts
7. Calls `store.SyncState().Upsert` with the source-provided `newCheckpoint` — always updates, even if zero messages stored

## Boundaries

| Boundary | Role | Used By | Key Types |
|----------|------|---------|-----------|
| `internal/storage` | Persistence — channels, messages, sync state | `refresh.go` (all methods), `refresh_test.go` (setup) | `Store`, `Channel`, `Message`, `SyncState` |
| `internal/source` | Generic feed abstraction | `refresh.go` (`RefreshSources`, `RefreshAllSources`) | `Source`, `SourceMessage`, `Registry` |
| `gotd/td/tg` | Telegram API SDK | `telegram.go` | `Client`, `Channel`, `Message`, `InputPeerChannel`, `MessagesGetHistoryRequest` |

Downstream consumers of this package: `cmd/digest/main.go` (instantiates `Service` and `TelegramFetcher`), `internal/tui` (uses refresh types in UI state).

## Non-Obvious Behaviors

- **`RefreshFiltered` is a no-op stub.** It ignores the `sourceNames` parameter entirely and delegates to `RefreshAll` (`refresh.go:122`). Callers expecting filtered behavior get a full refresh instead.

- **`NewMessages` count is inflated for the Telegram path.** `RefreshAll` adds `len(messages)` to `result.NewMessages` (`refresh.go:94`) regardless of whether `store.Messages().Create` succeeded or was silently deduplicated. The source path correctly counts only successful inserts (`refresh.go:168`).

- **Non-numeric external IDs get CRC32-hashed into `TelegramMsgID`.** When a source returns a non-integer `ExternalID` (e.g., a URL GUID from RSS), `RefreshSources` falls back to `crc32.ChecksumIEEE([]byte(msg.ExternalID))` cast to `int` (`refresh.go:155`). This reuses the `TelegramMsgID` column for non-Telegram content and means hash collisions would silently drop messages.

- **Checkpoint is always updated for sources, even with zero new messages.** `RefreshSources` calls `store.SyncState().Upsert` unconditionally after fetching (`refresh.go:172`), so the `LastSyncAt` timestamp advances even when nothing changed. The Telegram path only updates checkpoint when `len(messages) > 0` (`refresh.go:97`).

- **`extractMessages` silently drops non-text Telegram messages.** The filter at `telegram.go:81` requires both `*tg.Message` type assertion and `msg.Message != ""`. Service actions, media-only messages, and empty messages are all discarded without logging.

- **Sync state checkpoint parsing silently ignores errors.** At `refresh.go:71`, `strconv.Atoi(syncState.Checkpoint)` failures leave `afterMsgID` at 0, causing a full (non-incremental) fetch. This is the correct fallback but happens without any signal.

- **Error accumulation, not fail-fast.** Both `RefreshAll` and `RefreshSources` continue to the next channel/source on fetch errors, collecting errors in `result.Errors`. The top-level `error` return is only used for the initial `Channels().List` failure (`refresh.go:56`).

## Test Coverage Shape

The test suite is thorough for both paths with 14 test functions split across two groups.

**Well-tested:**
- Happy path for both Telegram (`RefreshAll`) and source (`RefreshAllSources`) pipelines
- Incremental sync: verifies `afterMsgID` is passed from stored checkpoint (Telegram), and that checkpoint string round-trips (sources)
- Sync state updates: confirms highest message ID is persisted as checkpoint
- Error continuation: fetch errors for one channel don't block others
- Deduplication via checkpoint: integration tests confirm second refresh yields 0 new messages
- Real source implementations: RSS, Reddit, and HackerNews each get an integration test with `httptest` servers serving realistic payloads

**Conspicuously absent:**
- No test for `RefreshFiltered` — its stub behavior (delegating to `RefreshAll`) is unverified
- No test for the CRC32 fallback path when `ExternalID` is non-numeric — the RSS/Reddit/HN integration tests presumably hit it, but no unit test isolates the behavior or checks for collision handling
- No test for `TelegramFetcher` or `extractMessages` — the entire `telegram.go` file has zero direct test coverage; it's only testable through the real Telegram API
- No test for the `NewMessages` over-count on the Telegram path (dedup via UNIQUE succeeds silently but count isn't adjusted)
- No negative test for malformed sync state checkpoints (e.g., non-integer string in the Telegram path)
