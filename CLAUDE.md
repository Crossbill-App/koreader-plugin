# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a KOReader plugin (Lua) that syncs book highlights and reading sessions to a Crossbill server. The plugin is installed by copying the `crossbill.koplugin` directory to KOReader's plugins folder.

## Development

**Testing on device**: Use the Makefile with a `.env` file containing the path to your device's KOReader plugins folder (`KOREADER_PLUGINS_PATH`): `make install` (production), `make install-test` (test version), `make install-all` (both). These wrap `scripts/copy_to_pocketbook.sh`, which builds the test plugin as a renamed copy with its own settings key and databases so both versions can run side by side.

**Linting and formatting**: `make lint` runs luacheck (config in `.luacheckrc`), `make format` runs StyLua (config in `.stylua.toml`).

**Unit tests**: `make test` runs busted over `spec/` (config in `.busted`). Specs are named `<module>_spec.lua` and target Lua 5.1, matching the LuaJIT KOReader runs plugins on. Because the plugin's modules `require` KOReader internals that do not exist outside the reader, `spec/support/koreader/` holds thin stand-ins (`logger`, `docsettings`, `ffi/sha2`, `device`, `random`, `json`, `gettext`, the `ui/*` widgets, and — for `main.lua` — `dispatcher`, `datastorage` and the `lua-ljsqlite3` binding) that `.busted` puts on `package.path` — so plugin sources never need test-only branches. `G_reader_settings` is a global rather than a module; `spec/support/global_settings_fake.lua` installs and restores it around a test. When one test needs different behaviour, prefer busted's `stub`/`spy` over growing a stub module.

`make check` runs lint, the formatting check and the tests. Keep `make check` green.

**Releases and the version**: never edit `version` in `crossbill.koplugin/_meta.lua`. The Release workflow owns it (`workflow_dispatch`, pick patch/minor/major): it bumps the line, commits it to main, tags it and publishes the plugin zip. CI fails any pull request whose `_meta.lua` evaluates to a different version than the one at its merge base (`scripts/check_version_unchanged.sh`, which compares the value rather than the text). Every request carries the version as `X-Crossbill-Client: koreader-plugin/<version>`, and the server refuses versions it no longer supports.

**No build step required** - Lua files are loaded directly by KOReader.

## Architecture

The plugin follows a modular architecture with dependency injection:

```
main.lua (CrossbillSync)
    ├── Settings        - Configuration persistence via KOReader's G_reader_settings
    ├── Auth            - OAuth token management (login, refresh, caching)
    ├── ApiClient       - HTTP API communication (highlights, sessions, files)
    ├── FileUploader    - EPUB uploads (uses ApiClient)
    ├── SessionTracker  - SQLite-based reading session tracking
    ├── SyncService     - Orchestrates sync workflow (uses ApiClient, FileUploader, SessionTracker)
    └── UI              - KOReader dialogs and menu building
```

**Key patterns:**

- `main.lua` is the entry point, extending KOReader's `WidgetContainer`
- All modules use constructor injection: `Module:new(dependencies)`
- API methods return consistent 3-tuples: `success/code, data, error`
- Network module handles WiFi lifecycle (enable before sync, disable after if we enabled it)

**Data flow:**

1. `BookMetadata` extracts title, author and ISBN from document
2. `HighlightExtractor` reads annotations from memory (preferred) or disk
3. `SyncService` coordinates upload of highlights, sessions, and files
4. `SessionTracker` stores reading sessions in SQLite (`crossbill_sessions.sqlite3`)

**Book identification:**

- `client_book_id`: MD5 hash of "title|author" - used for server-side deduplication
- `book_file_hash`: MD5 hash of file path - used for local session tracking

## KOReader Integration Points

- Event handlers: `onReaderReady`, `onPageUpdate`, `onSuspend`, `onResume`, `onCloseDocument`, `onExit`
- Menu registration: `addToMainMenu` via `self.ui.menu:registerToMainMenu(self)`
- Settings storage: `G_reader_settings` global
- Document access: `self.ui.document`, `self.ui.annotation`, `self.ui.toc`
