# Scout Context

## Entry Points

- tg-digest/internal/source/rss/rss.go:22 — NewRSSSource() constructs an RSSSource with name and feedURL
- tg-digest/internal/source/rss/rss.go:43 — FetchMessages() fetches new feed items since the checkpoint, applies conditional HTTP, filters by timestamp, and returns messages plus a new checkpoint
- tg-digest/internal/source/rss/rss.go:105 — fetchFeed() performs the HTTP GET with If-None-Match/If-Modified-Since headers and returns body, ETag, Last-Modified, and a notModified flag
- tg-digest/internal/source/rss/rss.go:151 — parseCheckpoint() splits a pipe-delimited checkpoint string into timestamp, ETag, and Last-Modified values
- tg-digest/internal/source/rss/rss.go:179 — buildCheckpoint() assembles a new pipe-delimited checkpoint string from timestamp, ETag, and Last-Modified

## Boundaries

Explore within:
- tg-digest/internal/source/rss/
- tg-digest/internal/source/source.go

Do NOT explore:
- tg-digest/internal/source/telegram/
- tg-digest/internal/source/reddit/
- Any other package outside the two paths above
- Vendor or external dependencies (github.com/mmcdole/gofeed, net/http, etc.)

## Max Depth

3 hops from any entry point.

## Notes

- Uses github.com/mmcdole/gofeed to parse RSS, Atom, and JSON Feed formats via gofeed.NewParser().ParseString()
- Conditional HTTP is implemented with If-None-Match (ETag) and If-Modified-Since headers; a 304 response short-circuits parsing and returns the existing checkpoint unchanged
- The checkpoint is a pipe-delimited RFC3339 string: `<rfc3339_timestamp>|<etag>|<last_modified>`; any or all parts may be empty
- Item deduplication uses GUID > Link > Title priority (itemID, line 194)
- Item text selection uses Content > Description > Title priority (itemText, line 207)
- Item timestamp selection uses PublishedParsed > UpdatedParsed > time.Now() (itemTimestamp, line 219)
- RSSSource implements the source.Source interface defined in tg-digest/internal/source/source.go
- SourceMessage fields populated: ExternalID, Title, Text, URL, Author, Timestamp
