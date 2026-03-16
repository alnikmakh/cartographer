# Findings Document Review

**Document**: `cartographer/exploration/findings.md`
**Source code**: `/home/dev/project/tg-digest/internal/source/`
**Reviewer**: Claude Opus 4.6 (automated verification against source code)
**Date**: 2026-03-16

---

## Accuracy Score: 9/10

## Completeness Score: 9/10

## Usefulness Score: 9/10

---

## Inaccuracies Found

### 1. Telegram test file lacks compile-time interface check

**Document claims** (Test Coverage Shape section): "Every test file includes a compile-time interface check (`var _ source.Source = (*XSource)(nil)`)."

**Actual code**: `telegram/telegram_test.go` does NOT contain a `var _ source.Source` line. The HN, Reddit, and RSS test files have it; Telegram's does not. The universal claim is false.

### 2. HN checkpoint scope is subtly wrong

**Document claims** (Non-Obvious Behaviors): "The checkpoint tracks the max ID across *all* fetched items, including deleted, dead, and non-story types."

**Actual code** (`hn.go:126-128`): Items whose HTTP fetch fails or returns nil are silently dropped from the results slice and never reach the checkpoint-tracking loop at line 157. The checkpoint only tracks max ID across *successfully fetched and parsed* items. If an item fetch fails, its ID is never seen by the checkpoint logic. The doc is correct that deleted/dead/non-story items contribute to checkpoint, but wrong that *all* fetched items do -- only successfully fetched ones.

### 3. RSS checkpoint format description oversimplified

**Document claims** (Flow 2, step 7): Checkpoint format is `RFC3339(newest_timestamp)|new_etag|new_last_modified`.

**Actual code** (`rss.go:185-187`): `buildCheckpoint` only appends the pipe-delimited etag/lastModified parts when at least one is non-empty. When both are empty, the checkpoint is a bare RFC3339 timestamp with no pipe characters. The Non-Obvious Behaviors section (line 118) describes the compound format correctly, but the data flow step oversimplifies by implying pipes are always present.

### 4. HN data flow step 9 has imprecise language

**Document claims**: "New checkpoint = `strconv.Itoa(max(all fetched IDs))` -- includes filtered items so the checkpoint advances even when everything is filtered."

**Actual code**: As noted in item 2, the max is over successfully fetched items, not "all fetched IDs." The IDs of items that failed to fetch are never tracked.

## Verified Correct (No Inaccuracies)

The following claims were all verified as fully accurate against source code:

- Source interface signature (3 methods, exact parameter types and return values)
- SourceMessage struct (all 6 fields with correct types)
- Registry methods (all 5 methods, exact signatures including return types)
- All four constructor signatures (parameters and types match)
- Strategy, Adapter, and Registry pattern identifications
- HN semaphore of 10 goroutines (`sem := make(chan struct{}, 10)`)
- HN insertion sort for restoring original index order
- HN URL hardcoded to `https://news.ycombinator.com/item?id={id}` (line 176)
- HN `composeText` logic: all four cases (URL+text, text-only, URL-only, title-only)
- HN filtering: Deleted, Dead, Type != "story", ID <= checkpointID
- Reddit User-Agent string exact match: `"tg-digest/1.0 (github.com/user/tg-digest)"`
- Reddit checkpoint is float64 unix timestamp with `<=` comparison
- Reddit `CreatedUTC` field typed as `float64` in JSON struct
- RSS conditional caching with ETag (`If-None-Match`) and Last-Modified (`If-Modified-Since`) headers
- RSS 304 handling returns `(nil, unchanged_checkpoint, nil)`
- RSS `time.Now()` fallback for items missing both `PublishedParsed` and `UpdatedParsed`
- RSS uses `gofeed.Parser` for both RSS 2.0 and Atom
- Registry.Add replaces by name silently (in-place overwrite, no return value)
- Telegram treats invalid checkpoints as 0 via ignored `strconv.Atoi` error
- Telegram messages populate only ExternalID, Text, and Timestamp (no Title, URL, or Author)
- All four sources use `http.DefaultClient.Do()` with no timeout
- Dependency diagram structure accurately reflects package relationships
- Boundary table correctly identifies all 5 boundaries with their roles and consumers
- Test coverage assessment: well-tested areas and notably absent areas are accurate

## Missing Important Details

1. **HN also silently treats invalid checkpoints as 0** (`hn.go:86-89`) -- same pattern as Telegram. The document calls this out for Telegram as a non-obvious behavior but omits it for HN.

2. **`limit` parameter semantics differ across sources.** HN truncates the story ID list before fetching (pre-fetch). Reddit passes limit as a URL query parameter to the API (server-side). RSS applies limit after parsing the full feed (post-parse). These differences have performance and correctness implications that a developer should know.

3. **RSS `itemID()` fallback chain** (GUID > Link > Title) is not documented. This determines how ExternalID is populated and matters for deduplication.

4. **Reddit hardcodes `https://www.reddit.com` in the URL field** (`reddit.go:125`) regardless of the `baseURL` field value. This means the SourceMessage URL always points to real Reddit even in tests.

5. **`WithBaseURL()` builder pattern** exists on HNSource and RedditSource for testing but not on RSSSource (which takes the URL directly in the constructor). This asymmetry in testability design is worth noting.

6. **RSS `buildCheckpoint` conditionally omits pipes** when no caching headers are present. A developer debugging checkpoint parsing needs to know the format is variable.

## Overall Assessment

This is an exceptionally high-quality architectural document. The vast majority of claims -- interface signatures, data flows, filtering logic, checkpoint mechanics, boundary identification, and non-obvious behaviors -- are factually correct and verified against source code. The four inaccuracies found are minor: one false universal claim about test patterns, one subtle imprecision about checkpoint scope with failed fetches, and two oversimplifications in data flow descriptions. The Non-Obvious Behaviors section is particularly valuable, capturing exactly the subtle details (silent checkpoint advancement, compound checkpoint strings, fallback to `time.Now()`, no Title in Telegram) that would otherwise require careful code reading to discover. A new developer or AI agent would get an accurate and immediately useful mental model from this document.
