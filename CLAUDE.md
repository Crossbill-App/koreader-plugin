# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a KOReader plugin (Lua) that syncs book highlights and reading sessions to a Crossbill server. The plugin is installed by copying the `crossbill.koplugin` directory to KOReader's plugins folder.

## Development

**Testing on device**: Use the Makefile with a `.env` file containing the path to your device's KOReader plugins folder (`KOREADER_PLUGINS_PATH`): `make install` (production), `make install-test` (test version), `make install-all` (both). These wrap `scripts/copy_to_pocketbook.sh`, which builds the test plugin as a renamed copy with its own settings key and databases so both versions can run side by side. Its `modules/` directory and its `_meta` are renamed too, and everything that requires them rewritten to match: Lua caches a module by name, so a name both copies use means whichever plugin KOReader loads first answers for both, and the production plugin reports the test build's name and version as its own. The script refuses to install a test build that still shares a name, rather than leaving that to be noticed on a device.

**Linting and formatting**: `make lint` runs luacheck (config in `.luacheckrc`), `make format` runs StyLua (config in `.stylua.toml`).

**Unit tests**: `make test` runs busted over `spec/` (config in `.busted`). Specs are named `<module>_spec.lua` and target Lua 5.1, matching the LuaJIT KOReader runs plugins on. Because the plugin's modules `require` KOReader internals that do not exist outside the reader, `spec/support/koreader/` holds thin stand-ins (`logger`, `docsettings`, `ffi/sha2`, `ffi/util`, `ffi/archiver`, `device`, `random`, `json`, `gettext`, the `ui/*` widgets, and — for `main.lua` — `dispatcher`, `datastorage` and the `lua-ljsqlite3` binding). `libs/libkoreader-lfs` hands over the real LuaFileSystem rather than a fake, and the `ffi/util` stand-in does real path and directory work, so the installer's staging and swap are tested against real directories — a swap with its arguments the wrong way round passes a mock and destroys a reader's plugin that `.busted` puts on `package.path` — so plugin sources never need test-only branches. `G_reader_settings` is a global rather than a module; `spec/support/global_settings_fake.lua` installs and restores it around a test. When one test needs different behaviour, prefer busted's `stub`/`spy` over growing a stub module.

`make check` runs lint, the formatting check and the tests. Keep `make check` green.

**Releases and the version**: never edit `version` in `crossbill.koplugin/_meta.lua`. The Release workflow owns it (`workflow_dispatch`, pick patch/minor/major): it bumps the line, commits it to main, tags it and publishes the plugin zip. CI fails any pull request whose `_meta.lua` evaluates to a different version than the one at its merge base (`scripts/check_version_unchanged.sh`, which compares the value rather than the text). Every request carries the version as `X-Crossbill-Client: koreader-plugin/<version>`, and the server refuses versions it no longer supports. `_meta.lua` also owns the project URL as `homepage`; the About menu item and the too-old-plugin message both read it from there, so never write that address out a second time. It owns `update_check_url` in the same way: `modules/update/check.lua` asks that address for the newest published release, so pointing the check at a different service is an edit to that one line. The Release workflow also signs the zip with the Ed25519 key in the `CROSSBILL_SIGNING_KEY` secret, publishes the detached signature as `crossbill.koplugin.zip.sig`, and fails if that signature matches no key in `crossbill.koplugin/modules/update/keys.lua` — so a release nobody could install never ships. Generate or rotate the key with `scripts/setup_signing_key.sh`.

**Updating the plugin from the device**: `modules/update/` holds the whole story — `check.lua` asks GitHub what the newest release is, `installer.lua` downloads and swaps it in, `signature.lua` verifies it, and `keys.lua` lists the public keys a release may be signed with. Nothing is installed that is not signed by one of those keys, and every way of being unable to check that refuses just as firmly; the reader is told to install by hand instead. `signature.lua` is the only `ffi.cdef` in the plugin, deliberately, so the rest stays testable — busted runs plain Lua 5.1, where `require("ffi")` fails and the module takes its fail-closed path.

The installer stages the new version as a sibling of the plugin directory and swaps it in with two renames, rather than writing over the plugin in place: a staging directory that fails halfway is thrown away, where a half-overwritten plugin would load and misbehave. It refuses when the archive's top-level directory does not match the plugin directory's name, which is what keeps the side-by-side test build from installing the production plugin over itself.

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
    ├── UI              - KOReader dialogs and menu building
    └── update/         - Checking for, verifying and installing a newer plugin
        ├── check.lua       - Asks the release service what the newest version is
        ├── installer.lua   - Downloads, verifies and swaps in a new version
        ├── signature.lua   - Ed25519 verification, the only FFI in the plugin
        └── keys.lua        - Public keys a release may be signed with
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
