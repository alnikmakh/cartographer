# Scout Context

## Entry Points

- tg-digest/internal/source/reddit/reddit.go:26 — NewRedditSource() constructs a RedditSource with subreddit, sort order, and limit; defaults sort to "hot" and limit to 25
- tg-digest/internal/source/reddit/reddit.go:88 — FetchMessages() fetches posts from the Reddit public JSON API, filters by checkpoint timestamp, and returns SourceMessage slice with updated checkpoint
- tg-digest/internal/source/reddit/reddit.go:142 — fetchListing() performs the HTTP GET against the Reddit .json endpoint, sets User-Agent, handles 429/404/non-2xx errors, and unmarshals the response
- tg-digest/internal/source/reddit/reddit.go:185 — postText() constructs message text differently for self-posts (title + selftext) vs link-posts (title + URL)

## Boundaries

Explore within:
- tg-digest/internal/source/reddit/
- tg-digest/internal/source/source.go

Do NOT explore:
- tg-digest/internal/source/ (any other files)
- tg-digest/internal/ (anything outside source/reddit/ and source/source.go)
- Any other package or directory in the repository

## Max Depth

3 hops from any entry point.

## Notes

- Uses Reddit's public JSON API (append .json to any subreddit URL); no authentication or API key required
- A custom User-Agent header is required — Reddit returns HTTP 429 without it (line 149)
- Sort orders supported: "hot", "new", "top" (stored in RedditSource.sort, line 19); defaults to "hot" (line 28)
- Checkpoint is a unix timestamp (float64 as string) representing the newest post seen; posts with created_utc <= checkpoint are skipped (line 117)
- Self-posts (IsSelf == true) include the post body (Selftext); link-posts include the external URL (line 185-193)
- Implements the source.Source interface defined in tg-digest/internal/source/source.go:9 (Type, Name, FetchMessages)
- WithBaseURL() at line 43 allows overriding the base URL for testing with httptest servers
- The redditListing, redditChild, and redditPost structs (lines 59-83) mirror the Reddit API JSON shape directly
