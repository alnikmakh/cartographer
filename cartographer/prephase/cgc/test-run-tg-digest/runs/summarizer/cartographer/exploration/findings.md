---
scope: internal/summarizer/service.go
files_explored: 9
boundary_packages: 2
generated: 2026-03-21T00:00:00Z
---

## Purpose

The `summarizer` package provides LLM-powered message summarization as a service that callers invoke after fetching content. From the caller's perspective (`cmd/digest/main.go`), it exposes a `Service` that either summarizes individual messages on demand (`SummarizeMessage`) or drains a time-windowed queue of all unsummarized messages (`SummarizeUnsummarized`, `SummarizeUnsummarizedForChannels`). The package owns provider selection — callers pick a `Client` implementation (Ollama or OpenRouter) at construction time and the service handles the rest.

## Architecture

```
                    ┌─────────────────────────────────────────┐
                    │           summarizer package             │
                    │                                          │
  [boundary]        │  ┌──────────┐    ┌──────────────────┐   │
  internal/storage ◄├──┤ service  ├───►│ prompt.go        │   │
                    │  │ (orch.)  │    │ BuildSingleMsg..  │   │
  [boundary]        │  └────┬─────┘    └──────────────────┘   │
  internal/source   │       │ via Client interface             │
  (sourceType str.) │  ┌────▼──────────────────────────┐      │
                    │  │       summarizer.go            │      │
                    │  │  Client interface              │      │
                    │  │  ChatRequest / ChatMessage     │      │
                    │  │  MessageSummarizeResult        │      │
                    │  │  SummarizeQueueResult          │      │
                    │  └──────┬──────────────┬──────────┘      │
                    │         │              │                  │
                    │  ┌──────▼──┐    ┌──────▼──────┐          │
                    │  │ollama   │    │openrouter   │          │
                    │  │(adapter)│    │(adapter)    │          │
                    │  └────┬────┘    └──────┬──────┘          │
                    │       │ reuses types   │                  │
                    └───────┼───────────────┼──────────────────┘
                            │               │
                    [Ollama HTTP API]  [OpenRouter API]
```

**Key interfaces and signatures**

```go
// summarizer.go
type Client interface {
    ChatCompletion(ctx context.Context, req ChatRequest) (string, error)
}

type ChatRequest struct {
    Model    string
    Messages []ChatMessage
}

type SummarizeQueueResult struct {
    Total     int
    Processed int
    Skipped   int    // short messages bypassed
    APIErrors int
    LastError error
}

// service.go
func NewService(client Client, model string, store storage.Store, opts ...ServiceOption) *Service
func (*Service) SummarizeMessage(ctx, *storage.Message, channelName, sourceType string) (*MessageSummarizeResult, error)
func (*Service) SummarizeUnsummarized(ctx context.Context) (*SummarizeQueueResult, error)
func (*Service) SummarizeUnsummarizedForChannels(ctx context.Context, channelIDs []int64) (*SummarizeQueueResult, error)

// prompt.go
func BuildSingleMessagePrompt(channelName, sourceType string, message *storage.Message) (system, user string, err error)
```

**Patterns**

- **Provider strategy via interface** (`summarizer.go:22-24`): `Client` with a single `ChatCompletion` method decouples `Service` from any specific LLM. Both `OllamaClient` and `OpenRouterClient` implement it; tests inject mock clients.
- **Functional options** (`service.go:20-37`): `ServiceOption` / `WithLocalModel()` extends `NewService` without breaking its signature. Currently one option exists; the pattern makes future additions cheap.
- **Shared wire format** (`openrouter.go:13-37`): The `openRouterRequest/Message/Response` types defined in `openrouter.go` are reused directly by `ollama.go` — both providers speak OpenAI-compatible JSON, so the types live in one place.

## Data Flow

**Queue summarization path**

```
SummarizeUnsummarized(ctx)
  │
  ├─ time window: start-of-yesterday UTC → end-of-today UTC (computed fresh each call)
  │
  ├─ store.MessageSummaries().GetUnsummarizedMessages(ctx, from, to) → []Message
  │
  └─ for each msg:
       store.Channels().GetByID(ctx, msg.ChannelID) → Channel
       │
       SummarizeMessage(ctx, msg, ch.Username, ch.SourceType)
         │
         ├─ len(msg.Text) < 150 → copy verbatim, Skipped=true
         │
         └─ len(msg.Text) >= 150:
              BuildSingleMessagePrompt(channelName, sourceType, msg)
                └─ system: singleMessageSystemPrompt [+ localModelPreamble if set]
                   user:   "Summarize this post from {type} {name}:\n\n{text}"
              │
              client.ChatCompletion(ctx, ChatRequest{Model, Messages}) → string
              │
              store.MessageSummaries().Create(ctx, &MessageSummary{...})
```

**Error containment**: `SummarizeUnsummarized` breaks on the first LLM error, records it in `LastError`, and returns `nil` as the Go error — the caller receives a partial result, not a failure.

**Single-message path** (`SummarizeMessage`): same logic but called directly by the orchestrator or TUI with a caller-supplied `channelName`/`sourceType`.

## Boundaries

| Boundary | Role | Consuming files | Key types | Coupling |
|---|---|---|---|---|
| `[Ollama HTTP API]` | Local LLM endpoint | `ollama.go` | POST `/v1/chat/completions`, GET `/`, GET `/api/tags` | direct HTTP |
| `[OpenRouter API]` | Cloud LLM endpoint | `openrouter.go` | POST `/chat/completions` with Bearer auth | direct HTTP |
| `internal/storage` | Persistence | `service.go`, `prompt.go` | `storage.Store`, `storage.Message`, `storage.MessageSummary`, `storage.Channel` | direct import |
| `internal/source` | Source type identity | `service.go` (via caller) | `sourceType string` embedded in user prompt | config-mediated (string passthrough) |

## Non-Obvious Behaviors

- **150-char heuristic is byte-length, not rune-length.** `len(message.Text) >= 150` in Go measures bytes. Multi-byte Unicode content (CJK, emoji) will reach the LLM threshold sooner than a Latin equivalent of the same visual length.

- **Queue stop is intentional, not a bug.** On the first LLM API error, `SummarizeUnsummarized` immediately breaks, records the error in `LastError`, and returns `nil` Go error with a partial `SummarizeQueueResult`. Callers that don't inspect `LastError` will silently accept incomplete processing as success (`service.go:113-116`).

- **Missed messages leave no trace.** If `Channels().GetByID()` fails or returns nil for any message in the queue, that message is silently `continue`d with no counter increment. The `Total` count reflects how many unsummarized messages were fetched; the gap between `Total` and `Processed + APIErrors` represents these silent drops (`service.go:106-109`).

- **Time window recalculates on every call.** `startOfYesterday`/`endOfToday` are derived from `time.Now().UTC()` inside the method. A run starting just before midnight will fetch a different window than a run starting just after — no configuration needed, but also no way to target a specific date range.

- **`localModelPreamble` is appended to, not replacing, the system prompt.** The extra conciseness instruction (`"Keep your response very concise (1-2 sentences max). Do not add preamble..."`) is concatenated after `singleMessageSystemPrompt` when `WithLocalModel()` is set (`prompt.go:18-20`, `service.go:50-51`). The base system prompt already specifies 1-3 sentences, so local model mode tightens to 1-2.

- **Ollama's 404 → actionable error.** A 404 from `/v1/chat/completions` is intercepted before the generic non-200 handler and converted to `"ollama pull <model>"` guidance (`ollama.go:66-68`). OpenRouter does not have equivalent error translation — non-200 responses surface raw body + status code.

- **OpenRouterClient has no HTTP timeout.** The `http.Client` is created with `&http.Client{}` (no `Timeout`), so request duration is bounded only by the context passed in. If the caller doesn't set a deadline, a hung server blocks forever (`openrouter.go:51`).

## Test Coverage Shape

Coverage is strong across the package. `service_test.go` uses a real SQLite database (`storage.Open` with a temp dir) rather than mocks — queue-stop semantics, channel filtering, and partial-progress persistence are all verified at the storage level, not just in memory. `ollama_test.go` and `openrouter_test.go` use `httptest.NewServer` to simulate API responses including error cases (404, 401, empty choices, malformed JSON, context cancellation). `prompt_test.go` is minimal — empty-text rejection and source-type embedding. The one gap: `HasModel`'s no-caching behavior has no performance regression test, and the silent-skip-on-channel-error path in `SummarizeUnsummarized` has no dedicated test case.
