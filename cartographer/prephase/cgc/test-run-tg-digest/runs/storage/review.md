# Review: storage package findings.md

## Scores

- **Accuracy score**: 9/10
- **Completeness score**: 8/10
- **Usefulness score**: 9/10

## Inaccuracies Found

1. **Test function count**: The document says "10 test functions" but the file contains **11** test functions. The three `TestMessageSummary_GetUnsummarizedByChannels_*` variants were likely miscounted as two.

2. **Minor line number imprecision on Channel List ordering**: The doc says `channels.go:148` for the `ORDER BY added_at DESC` clause. The actual ORDER BY is on line 147. The query spans lines 144-148 so this is a near-miss, not a hallucination.

3. **Minor line number imprecision on GetDistinctDates silent skip**: The doc says `messages.go:132` for the silent skip of unparseable dates. The `continue` statement is on line 131. Off by one.

4. **"IN (?)" description is slightly misleading**: The doc describes the dynamic SQL as building an `IN (?)` clause (line 131 of findings.md). The actual code builds `IN (?,?,...)` with one placeholder per channel ID via `strings.Join(placeholders, ",")`. The doc's description of the mechanism is correct; only the shorthand notation is slightly imprecise.

All other claims -- interface signatures, domain type fields, Open() flow with line numbers, message deduplication behavior, summary upsert semantics, nil-not-error return pattern, SourceType defaulting, single-connection pool, expandPath limitations, migration 004 behavior, and test coverage gaps -- are **verified correct** against the source code.

## Missing Important Details

1. **`scanChannel` handles nullable telegram_id via `sql.NullInt64`** (`channels.go:14-32`). This is a non-trivial implementation detail: the `Channel` struct uses a plain `int64` for `TelegramID`, but the database column is nullable. The scan helper bridges this gap. A developer modifying the Channel struct or adding new nullable fields would benefit from knowing this pattern exists.

2. **`CreateNonTelegram` passes `NULL` explicitly for telegram_id** in the SQL (`VALUES (NULL, ?, ?, ?)`), while `Create` passes the Go struct's `TelegramID` value. This asymmetry means calling `Create` with a zero-value `TelegramID` inserts `0` into the database, not `NULL`. This is a potential bug trap that the document does not flag.

3. **Migration transaction isolation**: The doc mentions migrations are wrapped in transactions but does not note the `defer tx.Rollback()` safety pattern in `applyMigration` (`migrations.go:88`), which ensures cleanup if `Commit()` is never reached.

4. **`GetByChannelAndDate` on messages returns results in `sent_at DESC` order** (`messages.go:49`), while the same-named method on message summaries returns results in `sent_at ASC` order (`message_summaries.go:75`). This inconsistency is worth flagging for developers who might assume uniform ordering.

5. **The `openTestStore` helper** creates databases in `t.TempDir()` (auto-cleaned), which is a useful pattern to note for anyone extending the test suite.

6. **No mention of the `stretchr/testify` dependency** used in tests. While minor, it is the only external test dependency.

7. **CASCADE delete behavior**: Migration 004 defines `FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE` on `message_summaries`. Combined with likely similar constraints on messages referencing channels, deleting a channel could cascade-delete messages and their summaries. This data-integrity behavior is not mentioned.

## Overall Assessment

This is a high-quality architectural document. Every interface signature, domain type, and behavioral claim was verified correct against the source code. The non-obvious behaviors section is particularly strong -- it identifies subtle semantics (silent dedup, nil-not-error, upsert-named-Create) that would genuinely trip up a new developer. The two real inaccuracies are a test count off by one and a couple of line-number off-by-ones, none of which would mislead a reader. The main gap is the missing coverage of the nullable `TelegramID` handling pattern and the ordering inconsistency between `GetByChannelAndDate` on messages (DESC) vs message summaries (ASC).
