---
scope: internal/source/registry.go
files_explored: 11
boundary_packages: 3
generated: TIMESTAMP
---

## Purpose

The `internal/source` package provides a unified interface for fetching content from heterogeneous external sources — Telegram channels, HackerNews, Reddit subreddits, and RSS/Atom feeds. Callers register `Source` implementations into a `Registry`, then query and invoke them uniformly via `FetchMessages(ctx, checkpoint, limit)` to perform incremental content ingestion. Each call returns new messages since the last checkpoint, enabling poll-based sync without the caller needing to know source-specific protocols.

## Architecture

**Dependency diagram**

```
source.go ─── defines ───→ Source interface + SourceMessage type
    ↑                              ↑ ↑ ↑ ↑
    │                              │ │ │ │
    │         ┌────────────────────┘ │ │ └────────────────────┐
    │         │              ┌───────┘ └───────┐              │
    │    hackernews/      reddit/           rss/         telegram/
    │      hn.go          reddit.go        rss.go       telegram.go
    │         │              │               │              │
    │    [Firebase API]† [Reddit API]†  [HTTP feeds]†  [refresh.Fetcher]†
    │
registry.go ─── manages ───→ []Source (add, remove, lookup)

† boundary packages / external services
```

**Key interfaces and signatures**

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
    Title      string
    URL        string
    Author     string
    Timestamp  time.Time
}

// registry.go
func NewRegistry() *Registry
func (r *Registry) Add(s Source)
func (r *Registry) Remove(name string) bool
func (r *Registry) List() []Source
func (r *Registry) ListByType(sourceType string) []Source
func (r *Registry) GetByName(name string) Source

// Constructors
func hackernews.NewHNSource(name, feed string, limit int) *HNSource
func reddit.NewRedditSource(name, subreddit, sort string, limit int) *RedditSource
func rss.NewRSSSource(name, feedURL string) *RSSSource
func telegram.NewTelegramSource(username string, fetcher refresh.Fetcher) *TelegramSource
```

**Pattern identification**

- **Strategy pattern** — `Source` is the strategy interface; four implementations provide source-specific fetching. The Registry holds and dispatches to them.
- **Adapter pattern** — `TelegramSource` wraps the pre-existing `refresh.Fetcher` interface to conform to `Source`. It bridges two abstraction layers.
- **Registry pattern** — `Registry` is a runtime container for named strategies with add/remove/lookup semantics. It replaces duplicates by name, not by type.

## Data Flow

**Flow 1: Fetch new HackerNews stories (happy path)**

1. Caller invokes `hnSource.FetchMessages(ctx, "43210", 30)`
2. `FetchMessages` parses checkpoint `"43210"` → `checkpointID = 43210`
3. `fetchStoryIDs` GETs `<baseURL>/v0/topstories.json` → returns `[]int` of story IDs
4. IDs are truncated to `limit` (30), then fetched concurrently via `fetchItem` with a **semaphore of 10** goroutines
5. Each `fetchItem` GETs `<baseURL>/v0/item/{id}.json` → returns `*hnItem` (or nil for `"null"` responses)
6. Results are insertion-sorted by original index to restore feed ordering
7. Items with `Deleted`, `Dead`, `Type != "story"`, or `ID <= checkpointID` are filtered out
8. Remaining items are mapped to `SourceMessage` — `URL` is always `https://news.ycombinator.com/item?id={id}` regardless of the item's own URL field
9. New checkpoint = `strconv.Itoa(max(all fetched IDs))` — includes filtered items so the checkpoint advances even when everything is filtered

**Flow 2: Fetch RSS with HTTP conditional caching**

1. Caller invokes `rssSource.FetchMessages(ctx, "2026-03-15T10:00:00Z|\"abc123\"|Sat, 15 Mar 2026 10:00:00 GMT", 0)`
2. `parseCheckpoint` splits on `|` → `(cutoffTime, etag="\"abc123\"", lastModified="Sat, 15 Mar 2026...")`
3. `fetchFeed` sends GET with `If-None-Match: "abc123"` and `If-Modified-Since` headers
4. If server returns **304 Not Modified** → returns `(nil, unchanged_checkpoint, nil)` immediately
5. Otherwise, response body is parsed via `gofeed.Parser` (handles RSS 2.0 and Atom)
6. Items with timestamp `<= cutoffTime` are filtered; `limit` is enforced if > 0
7. New checkpoint = `RFC3339(newest_timestamp)|new_etag|new_last_modified`

## Boundaries

| Boundary | Role | Used By | Key Types |
|----------|------|---------|-----------|
| `internal/refresh` | Telegram message fetching | `telegram/telegram.go` | `refresh.Fetcher`, `refresh.FetchedMessage` |
| Firebase API (`hacker-news.firebaseio.com`) | HN story data | `hackernews/hn.go` | HTTP JSON (story IDs, item objects) |
| Reddit API (`www.reddit.com`) | Subreddit posts | `reddit/reddit.go` | HTTP JSON (listing structure) |
| HTTP feed servers | RSS/Atom content | `rss/rss.go` | XML via `gofeed` library |
| `github.com/mmcdole/gofeed` | Feed parsing | `rss/rss.go` | `gofeed.Parser`, `gofeed.Item` |

## Non-Obvious Behaviors

- **HN checkpoint advances past filtered items.** The checkpoint tracks the max ID across *all* fetched items, including deleted, dead, and non-story types. This means the checkpoint window moves forward even when zero messages are returned, preventing re-fetching of filtered items on the next call. (`hackernews/hn.go:157-159`, `187-190`)

- **HN silently drops failed item fetches.** If an individual item HTTP request fails or returns nil, the goroutine returns without error — the item is simply absent from results. Only the story-ID-list fetch is fatal. (`hackernews/hn.go:126-128`)

- **HN URL field is always the HN discussion page**, not the submitted link. The item's own `URL` field goes into the `Text` body via `composeText`, while `SourceMessage.URL` is hardcoded to `https://news.ycombinator.com/item?id={id}`. (`hackernews/hn.go:176`)

- **Reddit requires a specific User-Agent or gets 429.** The header is hardcoded to `"tg-digest/1.0 (github.com/user/tg-digest)"`. (`reddit/reddit.go:149`)

- **Reddit checkpoint is a float64 unix timestamp**, not an integer. This means checkpoint comparison uses floating-point `<=`, which could theoretically miss posts with identical `created_utc` values (though Reddit timestamps have sub-second precision stored as float). (`reddit/reddit.go:101-103`, `117`)

- **RSS checkpoint is a compound string** (`RFC3339|etag|last_modified`) encoding three separate sync mechanisms in one field. This enables both content-level dedup (timestamp filtering) and HTTP-level bandwidth savings (304 responses) simultaneously. (`rss/rss.go:151-174`)

- **RSS falls back to `time.Now()` for items with no timestamp.** Items lacking both `PublishedParsed` and `UpdatedParsed` get the current time, which means they'll always pass the checkpoint filter on the first fetch but could be duplicated if the feed is re-fetched within the same second. (`rss/rss.go:219-227`)

- **Registry.Add replaces by name silently.** Adding a source with the same `Name()` as an existing source overwrites it in-place without returning any indication of replacement. (`registry.go:14-22`)

- **Telegram treats invalid checkpoints as 0.** `strconv.Atoi` failure is silently ignored via `_ = err`, defaulting to `afterMsgID = 0`, which means a corrupted checkpoint triggers a full re-fetch rather than an error. (`telegram/telegram.go:42`)

- **Telegram messages have no Title field.** Unlike all other sources that populate `SourceMessage.Title`, Telegram maps only `Text` and `Timestamp` from `FetchedMessage`. (`telegram/telegram.go:58-63`)

- **All sources use `http.DefaultClient`** with no timeout configuration. HN, Reddit, and RSS all call `http.DefaultClient.Do()`, meaning there's no per-request timeout beyond what the caller's `ctx` provides. (`hackernews/hn.go:204`, `reddit/reddit.go:151`, `rss/rss.go:119`)

## Test Coverage Shape

All four implementations and the registry have dedicated test files with strong coverage of happy paths and error scenarios. Every test file includes a compile-time interface check (`var _ source.Source = (*XSource)(nil)`).

**Well-tested:**
- Checkpoint parsing and filtering for all source types
- HTTP error handling (5xx, 404, 429, invalid URLs, malformed responses)
- Text composition logic (self-post vs link-post, URL+text combinations)
- Item filtering (HN: deleted/dead/non-story; Reddit/RSS: timestamp cutoff)
- Registry CRUD operations including duplicate-name replacement
- RSS conditional request round-trips (ETag → 304, Last-Modified → 304)

**Notably absent:**
- No concurrency-specific tests for HN's goroutine pool (tests exercise it indirectly via the mock server, but don't test race conditions or semaphore saturation)
- No tests for context cancellation mid-fetch in any source
- No integration tests — all HTTP sources use `httptest.Server` mocks
- No tests for `http.DefaultClient` timeout behavior (there is none to test)
- Registry has no concurrency safety tests — the `Registry` struct has no mutex, and concurrent `Add`/`Remove` calls would race on the `sources` slice
