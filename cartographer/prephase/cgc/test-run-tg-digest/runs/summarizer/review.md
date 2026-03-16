# Review: summarizer findings.md

Reviewed against source code in `/home/dev/project/tg-digest/internal/summarizer/`.

All 9 source files were read and every claim in the document was checked against the actual code.

## Scores

- **Accuracy score**: 9/10
- **Completeness score**: 9/10
- **Usefulness score**: 9/10

## Inaccuracies Found

1. **Minor: `openrouter.go:52` line reference is slightly off.** The document says `NewOpenRouterClient` creates `http.Client{}` at `openrouter.go:52`. The function starts at line 47 and `&http.Client{}` is on line 51. Off by one line.

2. **Minor: `SummarizeUnsummarizedForChannels` nil vs empty slice.** The test coverage section says "nil-channels-processes-all" (matching the test name), but the actual code at line 131 checks `len(channelIDs) == 0`, not `channelIDs == nil`. In Go `len(nil) == 0` so the behavior is the same, but the code also treats an empty non-nil slice identically. The document does not clarify this.

No hallucinated types, signatures, behaviors, or file references were found. Every function signature matches the actual code exactly. All line number references (except the one noted above) are accurate to the exact line. All struct fields are correct. The dependency diagram accurately represents the real import graph. The `Client` interface, both implementations, all `Service` methods, and `BuildSingleMessagePrompt` match verbatim.

## Missing Important Details

1. **`SummarizeUnsummarizedForChannels` duplicates the queue processing loop.** Lines 135-168 are a near-verbatim copy of lines 87-126 (the only differences being the storage method called and the error message). This code duplication is worth flagging for future developers but is not mentioned.

2. **`OpenRouterClient` endpoint path differs from `OllamaClient`.** Ollama uses `/v1/chat/completions` while OpenRouter uses `/chat/completions` (no `/v1` prefix). The document mentions both reuse the same wire types but does not call out this URL path difference, which matters for configuration and debugging.

3. **`BuildSingleMessagePrompt` rejects empty text.** The function returns an error at prompt.go:24-26 when `message.Text == ""`. The document shows the signature including `err error` but does not describe this validation behavior.

4. **`prompt_test.go` has 3 tests** (Success, EmptyText, DifferentSourceTypes) that are not mentioned in the "Well-tested" or test coverage section at all.

5. **`seedSingleMessage` test helper creates channels without `SourceType`.** This means queue-processing tests exercise `SummarizeMessage` with a zero-value (empty string) source type, which affects prompt content but is never verified.

## Overall Assessment

This is an exceptionally accurate architectural document. Every type definition, function signature, and behavioral claim was verified against source code and found correct or only trivially off (one line number, one nil-vs-empty nuance). The non-obvious behaviors section is the document's strongest asset -- it identifies subtle gotchas (byte-length threshold, silent channel-skip, stop-on-first-error returning nil error, string-based error detection, no OpenRouter timeout) that would genuinely save a developer from mistakes. The test coverage analysis correctly counts 12 Ollama tests and 6 OpenRouter tests, and the "conspicuously absent" items are legitimate gaps. A developer handed this document could confidently modify the summarizer package without first reading all the source.
