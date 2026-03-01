# Scout Context

## Entry Points

- tg-digest/internal/source/source.go:9 — Source interface defining the contract all source types must satisfy
- tg-digest/internal/source/source.go:11 — Type() method on Source returning the source type identifier string
- tg-digest/internal/source/source.go:15 — Name() method on Source returning the human-readable instance name
- tg-digest/internal/source/source.go:20 — FetchMessages() method on Source performing checkpoint-based incremental fetch
- tg-digest/internal/source/source.go:24 — SourceMessage struct, the universal message representation across all source types
- tg-digest/internal/source/registry.go:4 — Registry struct holding all configured sources
- tg-digest/internal/source/registry.go:9 — NewRegistry() constructor returning an empty Registry
- tg-digest/internal/source/registry.go:14 — Add() registering a source, replacing by name if already present
- tg-digest/internal/source/registry.go:36 — List() returning all registered sources
- tg-digest/internal/source/telegram/telegram.go:13 — TelegramSource struct adapting refresh.Fetcher to the Source interface
- tg-digest/internal/source/telegram/telegram.go:39 — FetchMessages() on TelegramSource showing checkpoint-as-message-ID pattern

## Boundaries

Explore within:
- tg-digest/internal/source/source.go
- tg-digest/internal/source/registry.go
- tg-digest/internal/source/telegram/telegram.go

Do NOT explore:
- tg-digest/internal/source/rss/
- tg-digest/internal/source/reddit/
- tg-digest/internal/source/hackernews/
- tg-digest/internal/source/registry_test.go
- tg-digest/internal/source/telegram/telegram_test.go
- tg-digest/internal/tui/
- tg-digest/internal/config/
- tg-digest/internal/storage/
- tg-digest/cmd/

## Max Depth

3 hops from any entry point.

## Notes

- Registry pattern: Registry is a plain slice-backed store; sources are keyed by Name(). Add() is an upsert — it replaces an existing source with the same name rather than appending a duplicate.
- Source interface defines exactly three methods: Type() string, Name() string, and FetchMessages(ctx, checkpoint, limit) ([]SourceMessage, string, error). Any type satisfying these three methods is a valid source.
- Checkpoint-based incremental fetch: FetchMessages accepts an opaque checkpoint string and returns a new checkpoint alongside the messages. An empty checkpoint signals a fresh initial fetch. The checkpoint format is source-specific (e.g., a Telegram message ID serialized as a string in TelegramSource).
- SourceMessage is the universal message struct shared across all source types. Fields Title, URL, and Author are optional and left empty by sources that do not produce them (e.g., Telegram).
- TelegramSource (telegram/telegram.go) is the canonical example of how a concrete type adapts an existing lower-level client (refresh.Fetcher) to the Source interface. All other source implementations in rss/, reddit/, and hackernews/ follow this same adapter pattern.
- Registry does not own fetching logic. Callers retrieve sources via List() or GetByName() and invoke FetchMessages() themselves.
