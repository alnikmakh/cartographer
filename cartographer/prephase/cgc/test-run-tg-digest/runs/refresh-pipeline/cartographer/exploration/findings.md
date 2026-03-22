---
scope: internal/refresh/refresh.go
files_explored: 3
boundary_packages: 4
generated: 2026-03-21T00:00:00Z
---

## Purpose

The refresh scope is the pipeline engine that drives content ingestion across all message sources. Callers (`cmd/digest/main.go`) invoke `RefreshAll` or `RefreshAllSources` to pull new messages into SQLite storage, advancing per-channel checkpoints so subsequent calls are incremental. The scope owns the `Fetcher` interface, which the CLI wires to a live Telegram MTProto client — or substitutes with a mock in tests. All caller-visible outcomes arrive through `RefreshResult`: channel counts, message counts, and a per-channel error list that never escalates a single failure into a top-level abort.

## Architecture

```
                       ┌──────────────────────────────────┐
                       │        internal/refresh          │
                       │                                  │
  [CLI / main.go] ───► │  Service                         │
                       │    RefreshAll()         ─────────┼──► [internal/storage]
                       │    RefreshFiltered()    ─────────┼──►   Channels.List
                       │    RefreshSources()     ─────────┼──►   SyncState.Get/Upsert
                       │    RefreshAllSources()  ─────────┼──►   Messages.Create
                       │                                  │
                       │  «interface» Fetcher             │
                       │    FetchNewMessages()            │
                       │         ▲                        │
                       │         │ implements             │
                       │  TelegramFetcher ────────────────┼──► [Telegram MTProto API]
                       │    (holds *tg.Client)            │       ContactsResolveUsername
                       │                                  │       MessagesGetHistory
                       └──────────────────────────────────┘
                                      │
                                      │ source path only
                                      ▼
                              [internal/source]
                               Source interface
                               Registry
                               SourceMessage
```

**Key interfaces and signatures:**

```go
// Abstraction point for Telegram; allows mock substitution in tests
type Fetcher interface {
    FetchNewMessages(ctx context.Context, username string, afterMsgID int, limit int) ([]FetchedMessage, error)
}

// Central result carrier — never returns top-level error for per-channel failures
type RefreshResult struct {
    ChannelsRefreshed int
    NewMessages       int
    Errors            []error
}

func NewService(fetcher Fetcher, store storage.Store, limit int) *Service
func (s *Service) RefreshAll(ctx context.Context) (*RefreshResult, error)
func (s *Service) RefreshAllSources(ctx context.Context, registry *source.Registry) (*RefreshResult, error)
```

**Pattern — dual refresh paths:** Two structurally distinct pipelines share the same `Service`. The Fetcher path (`RefreshAll`) is Telegram-specific: it uses integer message IDs as checkpoints stored as decimal strings, calls `s.fetcher.FetchNewMessages`, and only advances the checkpoint when messages arrive. The Source path (`RefreshAllSources` → `RefreshSources`) uses the `source.Source` interface, opaque string checkpoints (ETags, pagination cursors), and always advances the checkpoint regardless of whether messages were stored.

## Data Flow

**Telegram incremental sync (`RefreshAll`):**
```
store.Channels().List(ctx)
  → for each ch:
      store.SyncState().Get(ctx, ch.ID)     // checkpoint = "103" (last maxID)
      fetcher.FetchNewMessages(ctx, ch.Username, 103, limit)
        → TelegramFetcher: ContactsResolveUsername → MessagesGetHistory(MinID=103)
        → extractMessages: filters to non-empty tg.Message.Message, returns []FetchedMessage
      for each msg: store.Messages().Create(ctx, dbMsg)   // UNIQUE constraint = dedup
      store.SyncState().Upsert(ctx, maxID)  // scan full slice for max, not sorted order
```

**Generic source sync (`RefreshAllSources`):**
```
registry.List()
  → for each src:
      store.Channels().GetByUsername(ctx, src.Name())
      store.SyncState().Get(ctx, ch.ID)     // checkpoint = "etag:xyz" or ""
      src.FetchMessages(ctx, checkpoint, limit)
        → returns ([]SourceMessage, newCheckpoint, error)
      for each msg:
          msgID = strconv.Atoi(msg.ExternalID)    // integer IDs (HN)
                  OR crc32.ChecksumIEEE(ExternalID) // URL/alphanumeric IDs (RSS, Reddit)
          store.Messages().Create(ctx, dbMsg)
      store.SyncState().Upsert(ctx, newCheckpoint)  // always, even if stored==0
```

## Boundaries

| Boundary | Role | Coupling | Consuming files | Key types |
|---|---|---|---|---|
| `internal/storage` | Persistence layer | direct | `refresh.go` | `Store`, `Channel`, `Message`, `SyncState` |
| `internal/source` | Generic source interface | interface-mediated | `refresh.go`, `refresh_test.go` | `Source`, `Registry`, `SourceMessage` |
| `Telegram MTProto API` | External network | direct | `telegram.go` | `*tg.Client`, `tg.MessagesGetHistoryRequest` |
| `internal/telegram` | Session owner | consumed_by | (wires *tg.Client at startup) | `*tg.Client` passed into `NewTelegramFetcher` |
| `internal/summarizer` | Post-refresh consumer | event-driven | (none in this scope) | — |

## Non-Obvious Behaviors

- **`RefreshFiltered` is a no-op stub.** It accepts `sourceNames []string` but calls `return s.RefreshAll(ctx)` unconditionally (refresh.go:121-123). Any caller passing a source filter gets a full refresh of all channels instead. There is no mechanism in `Service` to honor filtered refresh.

- **Silent storage error swallowing in both paths.** `Messages.Create` errors are caught with `continue` in both `RefreshAll` (refresh.go:88-91) and `RefreshSources` (refresh.go:164-166). A storage failure (disk full, connection error) looks identical to a UNIQUE constraint duplicate. The message is lost and the error is not surfaced anywhere.

- **`NewMessages` counts mean different things per path.** `RefreshAll` increments `result.NewMessages += len(messages)` before any store operation — counting all fetched messages including those that fail Create. `RefreshSources` increments `result.NewMessages += stored` — counting only successfully stored messages. The same field carries different semantics depending on which path ran.

- **Source checkpoint advances even on zero stored.** In `RefreshSources`, `SyncState.Upsert(newCheckpoint)` executes unconditionally after the message loop (refresh.go:172-178). In `RefreshAll`, the parallel block only upserts `if len(messages) > 0` (refresh.go:97). This is semantically correct for Sources (ETags/cursors should advance), but means a Source fetch that yields no storable messages still writes a new checkpoint to the DB.

- **crc32 collision risk for non-integer IDs.** RSS GUIDs (full URLs) and Reddit post IDs (alphanumeric strings like `"abc123"`) are hashed into a 32-bit int via `crc32.ChecksumIEEE` and stored in the `TelegramMsgID` column (refresh.go:153-155). The 32-bit collision space is shared across all messages in a given channel — approximately 1-in-4B per pair, but with hundreds of messages in a single feed the birthday paradox starts to apply. A collision causes a real message to be silently dropped as a duplicate.

- **Username resolution takes the first channel in the response list.** `TelegramFetcher` iterates `resolved.Chats` and breaks on the first `*tg.Channel` (telegram.go:35-43). If a username resolves to both a linked discussion group and the main channel, whichever appears first in the Telegram API response wins — this is non-deterministic from the application's perspective.

- **`extractMessages` errors on unknown response variants.** The Telegram API can theoretically return `*tg.MessagesNotModified`. `extractMessages` handles three known variants and returns an error for anything else (telegram.go:65-77), propagating as a channel-level fetch error accumulated in `RefreshResult.Errors`.

## Test Coverage Shape

Coverage is strong and integration-first. `refresh_test.go` avoids mocking the store — it opens a real `storage.Open` against a `t.TempDir()` SQLite file for every test, exercising the full fetch→store→syncstate cycle against actual SQL. The Fetcher is mocked via `mockFetcher` (implementing the `Fetcher` interface) for Telegram path tests.

The source path has three full integration tests (`TestService_RefreshAllSources_RSSIntegration`, `_RedditIntegration`, `_HackerNewsIntegration`) that each spin up an `httptest.Server` serving fixture JSON/XML and run two consecutive refreshes — the second verifying that checkpoint-based deduplication suppresses re-ingestion of the same content.

Key behaviors covered: incremental sync (checkpoint passed as `afterMsgID`), per-channel error isolation (`FetchErrorContinues`), sync-state update with unsorted messages (maxID scan), checkpoint persistence and recall, and unknown-source-skipping. **Not covered:** the `RefreshFiltered` stub behavior, crc32 collision scenarios, the `extractMessages` unknown-type error path, or concurrent execution of `RefreshAll`.
