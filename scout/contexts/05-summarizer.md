# Scout Context

## Entry Points

- tg-digest/internal/summarizer/summarizer.go:22 — Client interface — LLM backend abstraction requiring ChatCompletion()
- tg-digest/internal/summarizer/service.go:28 — NewService() — constructs Service with a Client, model name, storage.Store, and optional ServiceOptions
- tg-digest/internal/summarizer/service.go:86 — SummarizeUnsummarized() — fetches all unsummarized messages from yesterday+today and processes them sequentially
- tg-digest/internal/summarizer/ollama.go:21 — NewOllamaClient() — constructs an OllamaClient hitting Ollama's OpenAI-compatible /v1/chat/completions endpoint
- tg-digest/internal/summarizer/openrouter.go:47 — NewOpenRouterClient() — constructs an OpenRouterClient for the OpenRouter cloud API
- tg-digest/internal/summarizer/prompt.go:23 — BuildSingleMessagePrompt() — builds system and user prompt strings for a single message

## Boundaries

Explore within:
- tg-digest/internal/summarizer/

Do NOT explore:
- tg-digest/internal/tui/
- tg-digest/internal/telegram/
- tg-digest/internal/source/
- tg-digest/internal/refresh/
- tg-digest/internal/config/
- tg-digest/cmd/
- Any *_test.go files
- tg-digest/internal/storage/ (reference interface signatures in message_summaries.go and messages.go only — do not traverse further into storage internals)

## Max Depth

5 hops from any entry point.

## Notes

- Two LLM backends: OllamaClient (local, hits /v1/chat/completions on a local Ollama server) and OpenRouterClient (cloud, hits OpenRouter's /chat/completions with a Bearer API key).
- Both backends implement the same Client interface (ChatCompletion) and reuse the same openRouterRequest/openRouterMessage/openRouterResponse JSON types defined in openrouter.go.
- Short message bypass: messages with fewer than 150 characters are copied verbatim as their own summary and marked Skipped=true; no LLM call is made (service.go:45).
- Summarization is per-message (not per-channel or per-batch); each message produces one MessageSummary row via storage.Store.MessageSummaries().Create().
- Prompt building (prompt.go:23) produces a fixed system prompt plus a user prompt that includes the source type, channel name, and raw message text.
- When localModel is set via WithLocalModel() (service.go:23), an extra preamble is appended to the system prompt instructing the model to be very concise and skip preamble text (prompt.go:18-20).
- SummarizeUnsummarized processes the queue sequentially and stops on the first API error, recording it in SummarizeQueueResult.LastError.
- SummarizeUnsummarizedForChannels (service.go:130) is a scoped variant that filters to specific channel IDs before processing.
