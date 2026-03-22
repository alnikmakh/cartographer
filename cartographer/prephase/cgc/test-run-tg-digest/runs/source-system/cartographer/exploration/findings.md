---
scope: internal/source/registry.go
files_explored: 11
boundary_packages: 2
generated: 2026-03-21
---

## Purpose

The `internal/source` package provides the unified abstraction for all content ingestion in tg-digest. Callers obtain a `*Registry`, populate it with `Source` implementations, then iterate via `Registry.List()` calling `FetchMessages(ctx, checkpoint, limit)` on each source to receive `[]SourceMessage` plus an updated checkpoint for next run. The checkpoint is stored externally (by `internal/storage`) and returned opaquely on subsequent calls — callers never parse it.

## Architecture

```
                    ┌─────────────────────────────┐
                    │        source.go (model)     │
                    │  interface Source            │
                    │  struct SourceMessage        │
                    └──────────────┬──────────────┘
                                   │ implements
          ┌───────────┬────────────┼────────────┬──────────────┐
          ▼           ▼            ▼            ▼              ▼
    hackernews/   reddit/       rss/        telegram/      registry.go
    hn.go         reddit.go     rss.go      telegram.go    (container)
    (adapter)     (adapter)     (adapter)   (adapter)
          │           │            │            │
          ▼           ▼            ▼            ▼
  [HN Firebase]  [Reddit API]  [Feed URL]  [internal/refresh]
                              [gofeed lib]   (boundary)

                    ┌──────────────────┐
                    │   registry.go    │◄── callers (internal/storage,
                    │  []Source slice  │     cli-orchestrator)
                    └──────────────────┘
```

**Key interfaces and signatures** (from source):

```go
// source.go
type Source interface {
    Type() string
    Name() string
    FetchMessages(ctx context.Context, checkpoint string, limit int) ([]SourceMessage, string, error)
}

type SourceMessage struct {
    ExternalID string
    Text       string
    Title      string    // empty for Telegram
    URL        string    // empty for Telegram
    Author     string
    Timestamp  time.Time
}
```

**Patterns:**
- **Opaque checkpoint**: `FetchMessages` returns a new checkpoint string whose format is implementation-defined. HN/Telegram encode the highest integer ID seen; Reddit encodes a float64 UTC timestamp; RSS encodes `<RFC3339>|<etag>|<last_modified>`.
- **WithBaseURL builder**: HNSource and RedditSource expose `WithBaseURL(url string) *T` for httptest injection without wrapping in an interface. RSSSource achieves the same via the `feedURL` constructor parameter.
- **Compile-time interface guard**: `var _ source.Source = (*HNSource)(nil)` in three test files. Missing from `telegram_test.go`.

## Data Flow

**Flow 1: HackerNews incremental fetch**
```
FetchMessages(ctx, "42000", 30)
  → GET /v0/topstories.json          → []int (story IDs)
  → filter IDs > 42000 (checkpoint)
  → concurrent GET /v0/item/{id}.json × up to 30  (semaphore=10)
  → insertion-sort results by original feed order
  → filter deleted/dead/non-story items
  → new checkpoint = max(ID across all fetched, including filtered)
  → return []SourceMessage, "42150", nil
```

**Flow 2: RSS with conditional HTTP**
```
FetchMessages(ctx, "2024-01-01T00:00:00Z|\"abc\"|Mon, 01 Jan 2024 00:00:00 GMT", 0)
  → parseCheckpoint → cutoffTime, etag, lastModified
  → GET feedURL with If-None-Match / If-Modified-Since headers
  → 304? → return nil, same_checkpoint, nil
  → gofeed.ParseString(body) → []gofeed.Item
  → filter items where ts <= cutoffTime
  → build new checkpoint = newest_ts|new_etag|new_last_modified
  → return []SourceMessage, newCheckpoint, nil
```

**Flow 3: Telegram via refresh boundary**
```
FetchMessages(ctx, "1234", 50)
  → strconv.Atoi("1234") → afterMsgID=1234
  → refresh.Fetcher.FetchNewMessages(ctx, username, 1234, 50)
                           → []refresh.FetchedMessage
  → convert: ExternalID=strconv.Itoa(TelegramMsgID), Text=fm.Text, Timestamp=fm.SentAt
  → maxID = max(TelegramMsgID across all messages)
  → return []SourceMessage, "1289", nil
```

## Boundaries

| Boundary | Role | Consuming Files | Coupling |
|---|---|---|---|
| `[HackerNews Firebase API]` | External REST API | `hackernews/hn.go` | direct (http.DefaultClient) |
| `[Reddit JSON API]` | External REST API | `reddit/reddit.go` | direct (http.DefaultClient) |
| `[RSS/Atom Feed URL]` | External HTTP feed | `rss/rss.go` | direct (http.DefaultClient) |
| `[github.com/mmcdole/gofeed]` | Third-party XML parser | `rss/rss.go` | direct (library import) |
| `[internal/refresh]` | Telegram fetch system | `telegram/telegram.go` | interface-mediated (`refresh.Fetcher`) |

`internal/storage` is a consumer of this scope (stores checkpoints and `SourceMessage` fields), not a dependency of it.

## Non-Obvious Behaviors

- **HN silent item drops**: When a goroutine fails to fetch an individual HN item (network error), the item is silently dropped and no error is returned. Callers can receive fewer results than `limit` with no indication of partial failure. (`hn.go:107-135`)

- **HN checkpoint includes filtered items**: The new checkpoint is the max ID across _all_ fetched items including deleted/dead/non-story ones. This is intentional — it prevents re-fetching junk on the next call — but means the checkpoint can advance past items that were never returned as messages. (`hn.go:151-169`)

- **RSS `time.Now()` fallback**: Feed items missing both `published` and `updated` dates get `time.Now()` as their timestamp. They will always be newer than the checkpoint, so they are returned on every fetch. High-traffic feeds with consistently undated items will produce duplicate deliveries. (`rss.go:219-227`)

- **RSS checkpoint preserves ETag on empty feed**: When `newest.IsZero()` (no items passed the filter), `buildCheckpoint` would return `""` — so `FetchMessages` explicitly falls back to the input checkpoint. This preserves ETag/Last-Modified for conditional requests on future calls. (`rss.go:95-98`)

- **Reddit same-second post loss**: Checkpoint filtering uses `<=` on float64 UTC timestamps. A post published at the exact same Unix second as the previous newest post is permanently skipped. (`reddit.go:100-119`)

- **Reddit URL hardcoded to canonical domain**: The `URL` field in `SourceMessage` is always `https://www.reddit.com` + permalink, regardless of any `baseURL` override used for testing. Tests do not assert this field. (`reddit.go:122-129`)

- **Reddit pagination not used**: The Reddit API returns an `after` pagination token but it is fetched and discarded — only the first page of results is returned per `FetchMessages` call. (`reddit.go:60-63`)

- **TelegramSource silent checkpoint reset**: `strconv.Atoi` with `_` error discard means a corrupted checkpoint string silently resets to `afterMsgID=0`, triggering a full re-fetch. This is tested explicitly but returns no error to the caller. (`telegram.go:41-43`)

- **Telegram messages have no Title or URL**: `SourceMessage.Title` and `SourceMessage.URL` are always empty for Telegram sources. Downstream consumers (summarizer, storage) must handle nil-like optional fields. (`telegram.go:58-63`)

- **Registry upsert by name, cross-type**: `Add` deduplicates by `Name()` only, not `Type()`. A `TelegramSource` named `"golang"` would silently replace an `RSSSource` also named `"golang"`. (`registry.go:14-21`)

- **Registry `List()` returns a copy, `Remove` mutates in place**: `List` makes a defensive copy so callers can't modify registry internals, but `Remove` uses slice-splice which modifies the underlying array. Both are correct for single-goroutine use, but the asymmetry is notable. (`registry.go:26-32, 36-40`)

## Test Coverage Shape

Coverage is strong across all four adapters:

- **HNSource** (`hn_test.go`): httptest mock server. Covers checkpoint advancement, order preservation under concurrent fetch, item filtering (deleted/dead/non-story), text composition, per-call limit override.
- **RedditSource** (`reddit_test.go`): httptest mock server. Covers success path, checkpoint filtering, 404/429/500 error codes, User-Agent header presence, URL construction.
- **RSSSource** (`rss_test.go`): httptest mock server with stateful request counter. Covers RSS 2.0 and Atom parsing, ETag round-trip, Last-Modified round-trip, 304 handling, checkpoint stability on empty feed, text composition priority (Content > Description > Title).
- **TelegramSource** (`telegram_test.go`): mockFetcher recording call arguments. Covers empty checkpoint (initial fetch), non-empty checkpoint parsed correctly, max-ID selection, error propagation, invalid checkpoint fallback to 0.
- **Registry** (`registry_test.go`): pure unit tests. Covers add, duplicate-name replace, remove, list, list-by-type, get-by-name.

Gap: `telegram_test.go` lacks the compile-time interface assertion present in the other three adapter test files. Minor but inconsistent.
