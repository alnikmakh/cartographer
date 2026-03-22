---
scopes_analyzed: 7
generated: 2026-03-21
---

## 1. System Map

```
                         ┌──────────────────────┐
                         │   cli-orchestrator    │
                         │   (cmd/digest/main)   │
                         │   God-file wiring     │
                         └──┬──┬──┬──┬──┬──┬────┘
                            │  │  │  │  │  │
              ┌─────────────┘  │  │  │  │  └─────────────┐
              ▼                ▼  │  ▼  │                 ▼
     ┌────────────┐  ┌─────────┐ │ ┌───┴──────┐  ┌──────────────┐
     │  telegram   │  │ refresh │ │ │ source   │  │     tui      │
     │  -client    │  │-pipeline│ │ │ -system  │  │              │
     │             │  │         │ │ │(registry │  │ Defines:     │
     │ MTProto     │  │ Fetcher │ │ │ +4 impls)│  │ RefreshSvc   │
     │ client,     │  │ Service │ │ └──────────┘  │ SummarizeSvc │
     │ Message     │  └────┬────┘ │      ▲        └──────┬───────┘
     │ type        │       │      │      │               │
     └──────┬──────┘       │      │      │               │
            │              ▼      │      │               │
            │     ┌────────────┐  │  ┌───┘               │
            └────►│  storage   │◄─┘  │                   │
                  │            │◄────┘                   │
                  │ Store iface│◄─────────────────────────┘
                  │ 4 repos    │         ▲
                  │ SQLite     │         │
                  └────────────┘    ┌────┴───────┐
                                    │ summarizer │
                                    │            │
                                    │ Client iface│
                                    │ Service    │
                                    └────────────┘
```

**Dependency direction summary:**

| From → To | Nature |
|---|---|
| cli-orchestrator → all 6 scopes | direct construction and wiring |
| refresh-pipeline → storage | direct (reads channels, sync state; writes messages) |
| refresh-pipeline → source-system | interface-mediated (Source, Registry) |
| source-system → refresh-pipeline | interface-mediated (telegram adapter uses refresh.Fetcher) |
| summarizer → storage | direct (reads unsummarized messages; writes summaries) |
| tui → storage | direct (reads channels, summaries; creates/deletes channels) |
| tui → refresh-pipeline | type-only (imports refresh.RefreshResult) |
| tui → summarizer | type-only (imports summarizer.SummarizeQueueResult) |

**Shared types crossing boundaries:**
- `storage.Store`, `storage.Channel`, `storage.Message`, `storage.MessageSummary`, `storage.SyncState` — consumed by cli-orchestrator, refresh-pipeline, summarizer, tui
- `source.Source`, `source.Registry`, `source.SourceMessage` — consumed by refresh-pipeline, cli-orchestrator
- `refresh.RefreshResult` — consumed by tui (types.go), cli-orchestrator
- `summarizer.SummarizeQueueResult` — consumed by tui (types.go)
- `telegram.Message` — consumed by cli-orchestrator (CLI fetch path only; not by refresh-pipeline which defines its own `FetchedMessage`)

**Notable: circular dependency between source-system and refresh-pipeline.** `source/telegram/telegram.go` imports `internal/refresh` for the `Fetcher` interface. `internal/refresh/refresh.go` imports `internal/source` for `Source` and `Registry`. This is a compile-time cycle avoided only because Go allows it at the package level (the telegram sub-package imports refresh, while refresh imports source — not source/telegram). But it creates a conceptual coupling loop.

## 2. Data Lineage

### Entity: `storage.Message`

**Defined:** `internal/storage/storage.go` — fields: `ID`, `ChannelID`, `TelegramMsgID`, `Text`, `SentAt`, `FetchedAt`.

**Producers:**
- **cli-orchestrator** (CLI path): constructs `Message` from `telegram.Message` in `storeMessages()`. Sets `TelegramMsgID` from `telegram.Message.ID` (native int). `Text` from `telegram.Message.Text`. `SentAt` from `telegram.Message.Timestamp`.
- **refresh-pipeline** (Telegram path): constructs `Message` from `FetchedMessage`. Same mapping as CLI path.
- **refresh-pipeline** (Source path): constructs `Message` from `source.SourceMessage`. `TelegramMsgID` is set to either `strconv.Atoi(ExternalID)` for integer IDs or `crc32.ChecksumIEEE(ExternalID)` for non-integer IDs. This repurposes an integer column designed for Telegram message IDs to hold hashed external identifiers.

**Consumers:**
- **summarizer**: reads via `GetUnsummarizedMessages()`. Uses `message.Text` for prompt construction, `message.ChannelID` to look up channel metadata. The 150-char bypass heuristic operates on `len(message.Text)` (byte length).
- **tui**: reads via `GetByChannelAndDate()` indirectly through summary display.

**Contract mismatch:** `TelegramMsgID` column has a `UNIQUE(channel_id, telegram_msg_id)` constraint used for deduplication. For Telegram sources this is a stable unique integer. For RSS/Reddit/HN sources it is a crc32 hash — a 32-bit space with birthday-problem collision risk. A collision silently drops a real message as a "duplicate" (refresh-pipeline findings, storage invariant on `ON CONFLICT DO NOTHING`).

**Contract mismatch:** When `Messages.Create` hits a duplicate, `message.ID` remains 0 (storage findings). The refresh pipeline ignores the return — safe. But any future caller that checks `message.ID` after `Create` will silently operate on ID 0.

### Entity: `SyncState.Checkpoint` (opaque string)

**Defined:** `internal/storage/storage.go` — `SyncState{ChannelID, Checkpoint, LastSyncAt}`.

**Producers & format by source type:**
- Telegram (refresh-pipeline Fetcher path): decimal string of max message ID, e.g. `"1234"`
- Telegram (source/telegram adapter): same format via `strconv.Itoa(maxID)`
- HackerNews: decimal string of max story ID, e.g. `"42150"`
- Reddit: float64 UTC timestamp as string, e.g. `"1710000000.000000"`
- RSS: pipe-delimited `"<RFC3339>|<etag>|<last_modified>"`

**Consumers:** All source adapters parse their own checkpoint format on the next `FetchMessages` call. The storage layer treats it as an opaque string — correct.

**Risk:** `source/telegram/telegram.go` silently falls back to `afterMsgID=0` on invalid checkpoint (confirmed by test `TestTelegramSource_FetchMessages_InvalidCheckpoint`). A corrupted checkpoint triggers a full re-fetch from the beginning. Other adapters have similar silent-fallback behavior — Reddit treats parse failure as `0.0` timestamp, RSS treats empty as initial fetch. No adapter returns an error on corrupt checkpoint. This is consistent but means checkpoint corruption is invisible.

### Entity: `storage.Channel`

**Defined:** `internal/storage/storage.go` — fields: `ID`, `TelegramID`, `Username`, `Title`, `SourceType`, `CreatedAt`.

**Producers:**
- **cli-orchestrator** CLI path (`storeChannel`): sets `Title = username` (raw `@username`), `SourceType` defaulted to `"telegram"` by storage.
- **cli-orchestrator** TUI path (`ensureSourceChannel`): creates via `CreateNonTelegram`. If `SourceType` is empty, storage defaults it to `"rss"` regardless of actual type.
- **tui** channels view: creates via `CreateNonTelegram` from the add-source wizard.

**Consumer:** summarizer reads `Channel.Username` and `Channel.SourceType` to construct LLM prompts (`BuildSingleMessagePrompt`). The prompt says "Summarize this post from {sourceType} {channelName}".

**Contract mismatch:** `SourceType` defaulting. Storage's `CreateNonTelegram` defaults empty `SourceType` to `"rss"` (storage findings). But the TUI's add-source wizard explicitly sets the type from user selection. The risk is in `ensureSourceChannel` in cli-orchestrator — if a HackerNews or Reddit source is created through this path and `SourceType` isn't set on the channel struct, it becomes `"rss"` in the DB, and the summarizer prompt will misidentify the source type.

### Entity: `RefreshResult`

**Defined:** `internal/refresh` — `RefreshResult{ChannelsRefreshed, NewMessages, Errors}`.

**Semantic inconsistency:** `NewMessages` means different things depending on which refresh path ran (refresh-pipeline findings). The Telegram path (`RefreshAll`) counts all fetched messages including those that fail storage `Create`. The Source path (`RefreshSources`) counts only successfully stored messages. The TUI displays this number to the user without distinguishing which path produced it.

## 3. Cross-Scope Findings

### 3.1 `RefreshFiltered` is broken end-to-end

**Scopes:** tui, cli-orchestrator, refresh-pipeline

**Evidence:** The TUI defines `RefreshService.RefreshFiltered(ctx, sourceNames)` (tui scope, types.go). The cli-orchestrator implements this via `registryRefreshAdapter` which does in-memory name-set filtering (cli-orchestrator manifest, patterns). But the underlying `refresh.Service.RefreshFiltered` ignores its `sourceNames` argument and delegates to `RefreshAll` unconditionally (refresh-pipeline manifest risk, refresh-pipeline findings: "refresh.go:121-123").

**Impact:** When the `registryRefreshAdapter` is used (sources configured), the adapter filters at the registry level before calling into refresh — so filtered refresh *works* for the Source path. But for the Telegram Fetcher path within `RefreshAll`, all Telegram channels are always refreshed regardless of filter. The user sees "filtered refresh" in the TUI but Telegram channels ignore the filter silently.

### 3.2 Silent error swallowing creates an invisible failure chain

**Scopes:** cli-orchestrator, refresh-pipeline, storage, summarizer

**Evidence:**
- `ensureSourceChannel` in cli-orchestrator swallows DB errors with `log.Printf` (cli-orchestrator manifest risk)
- `Messages.Create` duplicate returns `nil` with `message.ID = 0` (storage findings)
- Refresh pipeline treats all `Create` errors as duplicates via `continue` (refresh-pipeline invariant)
- Summarizer silently `continue`s when `Channels().GetByID()` fails or returns nil (summarizer manifest risk)

**Impact:** A disk-full or SQLite corruption error propagates through the system as follows: refresh writes fail silently (look like duplicates), sync state checkpoint advances anyway (Source path), next refresh sees the advanced checkpoint and skips the messages. They are permanently lost with no error surfaced anywhere. The summarizer then skips messages whose channel lookup fails, also silently. The only observable symptom is missing content in the TUI — no error, no log, no counter.

### 3.3 Dual message type creates a parallel universe

**Scopes:** telegram-client, refresh-pipeline, source-system

**Evidence:** `telegram.Message{ID, Text, Timestamp}` is defined in the telegram-client scope. `refresh.FetchedMessage` is defined in refresh-pipeline. `source.SourceMessage{ExternalID, Text, Title, URL, Author, Timestamp}` is defined in source-system. The `source/telegram` adapter converts `refresh.FetchedMessage` → `source.SourceMessage`, discarding `Title` and `URL` (always empty for Telegram — source-system findings). The CLI path in cli-orchestrator uses `telegram.Message` directly, bypassing both `FetchedMessage` and `SourceMessage`.

**Impact:** The CLI fetch path and the TUI refresh path produce structurally different `storage.Message` records from the same Telegram channel. The CLI path uses `telegram.FetchMessages` → `telegram.Message` → `storage.Message`. The TUI path uses `TelegramFetcher.FetchNewMessages` → `FetchedMessage` → `SourceMessage` → `storage.Message`. The mapping is semantically equivalent but the code paths share no implementation — a bug fix in one path won't fix the other.

### 3.4 HTTP timeout is missing system-wide

**Scopes:** source-system, summarizer, telegram-client

**Evidence:** All three scopes document the same risk independently:
- source-system: "Uses http.DefaultClient with no timeout" (manifest risks, repeated for HN, Reddit, RSS)
- summarizer: "http.Client created with no Timeout" (manifest risks, for both Ollama and OpenRouter)
- telegram-client: gotd client timeout not configured

**Impact:** A hung external service (HN Firebase, Reddit API, RSS feed, Ollama, OpenRouter) blocks the calling goroutine indefinitely unless the caller's context has a deadline. The summarizer and cli-orchestrator use `signal.NotifyContext` (SIGINT), but there is no per-request timeout. The TUI's auto-refresh fires on a ticker with no timeout on the refresh operation itself — a hung source blocks the entire refresh pipeline since sources are fetched sequentially.

### 3.5 `--summarize N` parameter is dead code across the boundary

**Scopes:** cli-orchestrator, summarizer

**Evidence:** cli-orchestrator findings: "The flag accepts a day-count but `SummarizeUnsummarized(ctx)` processes all unsummarized messages regardless of the N value." Summarizer findings confirm the time window is hardcoded to yesterday-through-today UTC, computed from `time.Now()` inside the method.

**Impact:** The CLI advertises a `--summarize N` flag that appears to control the summarization window, but N is silently discarded. The summarizer always processes today + yesterday. A user passing `--summarize 7` expecting a week of backfill gets two days.

### 3.6 `SourceType` defaulting diverges across creation paths

**Scopes:** storage, cli-orchestrator, tui, summarizer

**Evidence:** Storage's `Create` defaults empty `SourceType` to `"telegram"`. `CreateNonTelegram` defaults empty `SourceType` to `"rss"` (storage findings). cli-orchestrator's `ensureSourceChannel` creates channels for all source types using the config struct — but if `SourceType` isn't correctly propagated from config, storage silently assigns `"rss"`. The summarizer then uses `channel.SourceType` in prompt construction (summarizer findings).

**Impact:** A HackerNews source whose channel was created with a defaulted `SourceType` will have its messages summarized with "Summarize this post from rss {name}" instead of "from hackernews {name}". The LLM receives incorrect source context. The TUI's add-source wizard explicitly sets the type, so this only affects the cli-orchestrator path.

### 3.7 Timestamp timezone inconsistency at the telegram→storage→summarizer boundary

**Scopes:** telegram-client, storage, summarizer

**Evidence:** telegram-client findings: "`time.Unix(int64(msg.Date), 0)` uses the system's local timezone." Summarizer findings: "start-of-yesterday UTC → end-of-today UTC (computed fresh each call)." Storage's `GetUnsummarizedMessages` filters on `m.sent_at >= ? AND m.sent_at < ?` where the bounds are UTC `time.Time` values.

**Impact:** If the server's local timezone differs from UTC, Telegram message timestamps stored in SQLite carry local zone info. SQLite stores the formatted string representation of `time.Time`, which includes timezone. The summarizer's UTC-based time window query may miss messages near the day boundary — messages timestamped near midnight local time could fall outside the UTC yesterday-through-today window. The severity depends on the timezone offset of the deployment environment.

### 3.8 source/telegram creates a structural cycle between source-system and refresh-pipeline

**Scopes:** source-system, refresh-pipeline

**Evidence:** `source/telegram/telegram.go` imports `internal/refresh` to use the `Fetcher` interface (source-system findings, boundary table). `internal/refresh/refresh.go` imports `internal/source` for `Source` and `Registry` (refresh-pipeline manifest).

**Impact:** Go compiles this because the import is `source/telegram` → `refresh` and `refresh` → `source` (different packages). But conceptually, source-system and refresh-pipeline have a bidirectional dependency. This makes it impossible to reason about either scope in isolation and creates a risk of actual import cycles if either package is restructured. The Fetcher interface should arguably live in the source package or a shared interface package.

## 4. Systemic Patterns

### Error Handling

**Convention:** Accumulate per-item errors, never abort the batch. Return a result struct with an error list.

| Scope | Follows? | Notes |
|---|---|---|
| refresh-pipeline | Yes | `RefreshResult.Errors` accumulates per-channel failures |
| summarizer | Partial | Breaks on first LLM error, returns partial result with `LastError` — does not accumulate |
| cli-orchestrator | No | Uses `log.Fatalf` for startup failures; `log.Printf` + silent continue for runtime errors in helpers |
| storage | N/A | Returns individual errors; dedup is `nil` return |
| telegram-client | No | Errors propagate directly; no accumulation pattern |
| tui | Yes | Displays errors via `errMsg` with auto-clear timer; never crashes |

**Deviation:** The summarizer's break-on-first-error deviates from the accumulate pattern. The cli-orchestrator's `ensureSourceChannel` deviates by swallowing errors entirely.

### Config Management

**Convention:** YAML config loaded once at startup by cli-orchestrator; downstream scopes receive typed values or constructed services.

All scopes follow this. No scope reads config independently — cli-orchestrator is the sole config consumer. The one deviation is Reddit sort defaulting, which is split: config doesn't default it, cli-orchestrator defaults to `"hot"` at registration time (cli-orchestrator findings).

### HTTP Client Usage

**Convention:** No convention exists — this is the problem.

| Scope | HTTP Client | Timeout |
|---|---|---|
| source-system (HN, Reddit, RSS) | `http.DefaultClient` | None |
| summarizer (Ollama) | `&http.Client{}` | None |
| summarizer (OpenRouter) | `&http.Client{}` | None |
| telegram-client | gotd-managed | None configured |

Every scope that makes HTTP calls lacks explicit timeouts. Context cancellation is the only bound everywhere.

### Test Strategy

**Convention:** Integration tests against real SQLite in `t.TempDir()`; mock only external network calls via `httptest.Server`.

| Scope | Follows? | Notes |
|---|---|---|
| storage | Yes | `openTestStore` with real SQLite |
| refresh-pipeline | Yes | Real SQLite + `mockFetcher` for Telegram |
| source-system | Yes | `httptest.Server` for all HTTP sources |
| summarizer | Yes | Real SQLite + `httptest.Server` for LLM |
| tui | Yes | Real SQLite + mock `RefreshService`/`SummarizeService` |
| cli-orchestrator | Partial | Only `buildLLMClient` tested; helpers untested |
| telegram-client | No | Zero test files; requires live MTProto connection |

This is a strong, consistent pattern. The only deviations are telegram-client (untestable without mocking gotd) and cli-orchestrator (thin wiring, partially tested).

### Dependency Inversion

**Convention:** Consumer defines the interface.

| Interface | Defined in | Consumed by | Follows? |
|---|---|---|---|
| `RefreshService` | tui (types.go) | cli-orchestrator adapter | Yes |
| `SummarizeService` | tui (types.go) | cli-orchestrator adapter | Yes |
| `Client` (LLM) | summarizer (summarizer.go) | summarizer service | Yes |
| `Source` | source-system (source.go) | refresh-pipeline | Yes |
| `Fetcher` | refresh-pipeline (refresh.go) | source/telegram adapter | **Inverted** — defined in provider's consumer, consumed by provider's sibling |
| `Store` | storage (storage.go) | everyone | Central hub — neither pattern |

The `Fetcher` interface is the only violation. It is defined in refresh-pipeline but consumed by `source/telegram`, creating the structural cycle noted in §3.8.

### Naming Conventions

Consistent across scopes: `New*` constructors, `*Repository` for data access, `*Service` for orchestration, `*Client` for external API adapters. The one naming anomaly is `TelegramMsgID` in `storage.Message` — it stores non-Telegram IDs (crc32 hashes) for RSS/Reddit/HN sources, making the name misleading.

## 5. Architectural Assessment

### Scope Boundary Quality

**Well-placed boundaries:**
- **storage** is a clean hub with no outbound dependencies. Every other scope depends on it; it depends on nothing. The interface-based API prevents leaking SQL details.
- **tui** uses dependency inversion correctly — it defines the service interfaces it needs and never imports refresh or summarizer directly (only their result types in types.go).
- **summarizer** has a clean, focused responsibility with a single-method `Client` interface for provider abstraction.

**Poorly-placed boundary:**
- **source/telegram** should not exist as a sub-package of source-system. It imports refresh-pipeline's `Fetcher` interface, creating a conceptual cycle. The Telegram source adapter is fundamentally different from the HTTP-based sources — it wraps an existing internal service rather than an external API. It would fit better as part of refresh-pipeline or as a standalone adapter package.

### Structural Debt

- **God-file orchestrator:** `cmd/digest/main.go` contains all wiring, both adapter types, and six helper functions. It is the only file that imports all six internal packages. This is acceptable for the current codebase size but will not scale — any new operating mode or service requires modifying this single file.

- **`TelegramMsgID` column abuse:** The `messages.telegram_msg_id` column with its `UNIQUE` constraint was designed for Telegram integer message IDs. It now stores crc32 hashes of arbitrary strings. The column name is misleading, the 32-bit hash space introduces collision risk, and the schema migrations don't reflect this semantic change.

- **Dual Telegram paths:** CLI mode and TUI mode use completely different code paths to fetch and store Telegram messages. CLI uses `telegram.FetchMessages` → `storeMessages`. TUI uses `refresh.TelegramFetcher` → `refresh.Service.RefreshAll`. Both produce `storage.Message` records but share no implementation.

### Missing Scopes

- **No config scope.** `internal/config` is bundled inside `cmd/digest` and unexposed. If any other entry point (a future HTTP server, a CLI migration tool) needs config parsing, it must duplicate the logic or be folded into `cmd/digest`.

### Scalability Concerns

- **Single SQLite connection:** Storage uses one `*sql.DB` shared across all repositories. SQLite's write serialization means concurrent refresh + summarize operations block each other. The migration race condition (storage findings) confirms there is no locking strategy.

- **Sequential source refresh:** `RefreshAllSources` iterates sources sequentially. A slow or hung source (no HTTP timeout — §3.4) blocks all subsequent sources. There is no parallelism or per-source timeout.

- **O(N) message insertion:** Both cli-orchestrator (`storeMessages`) and refresh-pipeline insert messages one at a time in a loop. For channels with high message volume, this is O(N) SQLite round-trips per refresh cycle.
