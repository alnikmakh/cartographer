# Review: refresh-pipeline findings.md

**Reviewed**: 2026-03-16
**Reviewer**: Claude Opus 4.6 (line-by-line verification against source code)
**Method**: Read every source file referenced in the document, verified every signature, line reference, data flow step, and behavioral claim.

## Scores

- **Accuracy score**: 9/10
- **Completeness score**: 8/10
- **Usefulness score**: 9/10

## Inaccuracies Found

1. **Line reference off by one for checkpoint parsing.** The document says `refresh.go:71` for the `strconv.Atoi(syncState.Checkpoint)` silent error. The actual assignment `afterMsgID, _ = strconv.Atoi(syncState.Checkpoint)` is on line 70. Line 71 is blank. Minor but matters when navigating by line number.

2. **Oversimplified description of `GetByUsername` error handling in the source path (Flow 2, step 2).** The document says "if no matching channel exists, silently skips." In reality there are two distinct cases at `refresh.go:130-137`: (a) if `GetByUsername` returns a non-nil error, the error is appended to `result.Errors` and the source is skipped (not silent); (b) if `ch == nil` (no error, channel not found), it silently skips via bare `continue`. The document collapses both cases into "silently skips," which is inaccurate for the error case.

3. **`ContactsResolveUsername` call description omits request struct.** Flow 1, step 4 says "calls `api.ContactsResolveUsername`." The actual call is `f.api.ContactsResolveUsername(ctx, &tg.ContactsResolveUsernameRequest{Username: cleanName})`. The request struct wrapping is omitted. Cosmetic, but a developer copying the pattern would need the struct.

All three are minor. Every interface signature, every struct definition, every type assertion, every behavioral claim about counting/checkpointing/dedup checks out against the actual source code. The document is remarkably precise.

## Verification of Key Claims

The following claims were verified line-by-line and confirmed correct:

- All 6 function signatures in the "Key interfaces and signatures" block match the source exactly.
- `RefreshFiltered` at line 122 does delegate to `RefreshAll`, ignoring `sourceNames` -- confirmed.
- `NewMessages` over-count at line 94: `result.NewMessages += len(messages)` regardless of dedup -- confirmed.
- Source path correctly counts only inserts at line 170: `result.NewMessages += stored` -- confirmed.
- CRC32 fallback at line 155: `msgID = int(crc32.ChecksumIEEE([]byte(msg.ExternalID)))` -- confirmed.
- Unconditional checkpoint update for sources at line 172 vs conditional at line 97 for Telegram -- confirmed.
- `extractMessages` filter at `telegram.go:81` requiring both `*tg.Message` and non-empty `.Message` -- confirmed.
- Error accumulation pattern with fail-fast only for `Channels().List` at line 56 -- confirmed.
- 14 test functions in `refresh_test.go` -- confirmed by count.
- All test coverage claims (what is and isn't tested) -- confirmed accurate.

## Missing Important Details

1. **`SourceMessage` has fields discarded during conversion.** The `source.SourceMessage` struct has `Title`, `URL`, and `Author` fields (see `internal/source/source.go:25-31`). The refresh package discards all three when converting to `storage.Message` -- only `ExternalID`, `Text`, and `Timestamp` survive. This data loss is worth noting for anyone adding features that need article titles or URLs.

2. **`Registry` has additional methods beyond what the document covers.** `Remove(name)`, `ListByType(sourceType)`, and `GetByName(name)` exist on the Registry struct. These are relevant for understanding how sources could be filtered or managed outside of the refresh flow.

3. **`ChannelRepository` has `CreateNonTelegram` method.** The test file uses `Create` for seeding channels, and the channel struct has a `SourceType` field. How non-Telegram channels are persisted differently is relevant context for the source-based refresh path.

4. **`Store` interface has a fourth repository: `MessageSummaries()`.** The document correctly omits it from its scope (refresh doesn't use it), but a developer unfamiliar with the broader system might assume `Store` only has the three repositories shown.

5. **SQLite single-connection pool.** The storage layer uses `db.SetMaxOpenConns(1)`, which has concurrency implications for any future parallelization of refresh.

## Comparison to Previous Review

A prior review (also automated) scored this document 7/7/8. After line-by-line verification, several of that review's claimed inaccuracies were themselves inaccurate or overstated:

- The prior review claimed the document missed `RefreshSources` and `RefreshFiltered` -- the document actually covers both (lines 68-70 in signatures, line 119 in non-obvious behaviors).
- The prior review claimed the document missed the CRC32 fallback -- the document covers it in detail (line 123, non-obvious behaviors).
- The prior review claimed the document missed the `extractMessages` filter -- the document covers it (line 127, non-obvious behaviors).
- The prior review's point about composite UNIQUE constraint is valid but was not claimed incorrectly by the document -- the document says "UNIQUE constraint silently deduplicates" which is accurate regardless of whether the constraint is single-column or composite.

## Overall Assessment

This is a high-quality architectural document. Every function signature matches the source code exactly. The data flow descriptions for both the Telegram and generic source paths are accurate step-by-step with correct line references (off by one in a single case). The non-obvious behaviors section is the document's strongest contribution -- it correctly identifies the NewMessages over-count bug, the CRC32 collision risk, the RefreshFiltered stub, the unconditional checkpoint update asymmetry, and the silent checkpoint parsing fallback. The test coverage analysis accurately identifies both what is tested and what is conspicuously absent. A new developer or AI agent could use this document to understand and safely modify the refresh package with high confidence.
