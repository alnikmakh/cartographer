# Scout Context

## Entry Points

- tg-digest/internal/config/config.go:63 — Load() reads and parses the YAML config file at the given path, applies defaults, runs backward-compat migration, expands paths, and calls validate()
- tg-digest/internal/config/config.go:125 — validate() checks all required fields across Telegram, Storage, LLM, and Sources sections
- tg-digest/internal/config/config.go:174 — expandPath() expands ~ prefix to the user's home directory

## Boundaries

Explore within:
- tg-digest/internal/config/

Do NOT explore:
- tg-digest/internal/tui/
- tg-digest/internal/telegram/
- tg-digest/internal/source/
- tg-digest/internal/summarizer/
- tg-digest/internal/refresh/
- tg-digest/internal/storage/
- tg-digest/cmd/
- any _test.go files

## Max Depth

3 hops from any entry point.

## Notes

- YAML parsing is done via gopkg.in/yaml.v3 (imported at config.go:9)
- Backward compatibility: if llm.provider is empty but openrouter.api_key is set, the old openrouter section is migrated into the new llm section (config.go:85-92)
- Path expansion via expandPath() is applied to both the config file path itself and to telegram.session_file and storage.db_path after parsing (config.go:119-120)
- This is a single-file package; all types (Config, TelegramConfig, StorageConfig, OpenRouterConfig, RefreshConfig, LLMConfig, SourceConfig) and all logic live in config.go
- Default values are applied for OpenRouter model/base URL, LLM timeouts (120s for ollama, 30s for openrouter), and refresh interval (30 minutes)
