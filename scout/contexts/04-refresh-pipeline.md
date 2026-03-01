# Scout Context

## Entry Points

- tg-digest/internal/refresh/refresh.go:44 — NewService() constructs the refresh Service with a Fetcher, storage.Store, and per-channel message limit
- tg-digest/internal/refresh/refresh.go:53 — RefreshAll() fetches new messages for every stored channel using incremental sync checkpoints
- tg-digest/internal/refresh/refresh.go:121 — RefreshFiltered() entry point for named-source refresh; delegates to RefreshAll() when no registry is attached
- tg-digest/internal/refresh/refresh.go:29 — Fetcher interface (FetchNewMessages) abstracts the Telegram transport layer for testability

## Boundaries

Explore within:
- tg-digest/internal/refresh/
- tg-digest/internal/source/source.go (interface and SourceMessage type only)
- tg-digest/internal/storage/storage.go (Store interface)
- tg-digest/internal/storage/syncstate.go (SyncStateRepository interface)
- tg-digest/internal/storage/messages.go (MessageRepository interface)
- tg-digest/internal/storage/channels.go (ChannelRepository interface)

Do NOT explore:
- tg-digest/internal/tui/
- tg-digest/internal/config/
- tg-digest/internal/summarizer/
- tg-digest/cmd/
- tg-digest/internal/refresh/refresh_test.go (and any other _test.go files)
- tg-digest/internal/storage/migrations/
- tg-digest/internal/storage/storage_test.go
- tg-digest/internal/source/ (any file other than source.go)
- github.com/gotd/td (Telegram client internals)

## Max Depth

5 hops from any entry point.

## Notes

- The Fetcher interface (refresh.go:29) decouples the pipeline from the Telegram wire protocol; TelegramFetcher (telegram.go:13) is the production implementation, but tests can substitute any Fetcher.
- source.Registry (source package) enables multi-source refresh: RefreshAllSources() (refresh.go:188) accepts a *source.Registry, calls registry.List(), and dispatches to RefreshSources() (refresh.go:126) which uses the generic source.Source interface rather than the Telegram-specific Fetcher.
- Incremental sync is implemented via string checkpoints stored in storage.SyncState. For Telegram sources the checkpoint is the highest seen message ID (stored as a decimal string). For generic sources the checkpoint format is source-defined and round-tripped opaquely through source.Source.FetchMessages().
- When a UNIQUE constraint violation occurs on message insert (refresh.go:88-91, 164-166), the error is silently skipped — this is intentional deduplication, not a bug.
- RefreshFiltered() (refresh.go:121) currently falls back to RefreshAll() because Service holds no registry reference; callers that need true filtered refresh should use RefreshAllSources() with a filtered registry.List() result passed directly to RefreshSources().
