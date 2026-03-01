# Scout Context

## Entry Points

- tg-digest/internal/source/hackernews/hn.go:41 — NewHNSource() constructs HNSource with feed type, limit, and Firebase base URL
- tg-digest/internal/source/hackernews/hn.go:76 — FetchMessages() fetches stories for the configured feed, filters by checkpoint, returns messages and new checkpoint
- tg-digest/internal/source/hackernews/hn.go:196 — fetchStoryIDs() retrieves ordered list of story IDs from the Firebase feed endpoint
- tg-digest/internal/source/hackernews/hn.go:228 — fetchItem() fetches a single HN item by ID; returns nil on HTTP "null" response
- tg-digest/internal/source/hackernews/hn.go:261 — composeText() builds message text from item title, body text, and URL

## Boundaries

Explore within:
- tg-digest/internal/source/hackernews/
- tg-digest/internal/source/source.go

Do NOT explore:
- tg-digest/internal/source/ (other subdirectories)
- tg-digest/internal/ (other packages)
- Any external packages or standard library internals

## Max Depth

3 hops from any entry point.

## Notes

- Uses the HackerNews Firebase REST API (https://hacker-news.firebaseio.com/v0/) for both feed lists and individual item fetches.
- Feed types supported: top, best, new, ask, show, job — configured at construction time; defaults to "top" if empty.
- Story IDs are fetched as an ordered list then truncated to the configured limit before concurrent item fetching begins.
- Items are fetched concurrently using goroutines bounded by a semaphore channel of size 10.
- Original feed order is preserved after concurrent fetch via insertion sort on a tracked index.
- Items are filtered out if: Deleted == true, Dead == true, or Type != "story".
- Checkpoint is the highest item ID seen across the fetched batch (including filtered items); stored as a decimal string.
- Items with ID <= checkpoint are excluded from returned messages but still advance the checkpoint.
- Implements the Source interface defined in tg-digest/internal/source/source.go.
- WithBaseURL() exists for test injection of a mock Firebase server.
