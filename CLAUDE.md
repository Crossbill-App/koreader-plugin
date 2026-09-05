# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a KOReader plugin (Lua) that syncs book highlights and reading sessions to a Crossbill server. The plugin is installed by copying the `crossbill.koplugin` directory to KOReader's plugins folder.

## Development

**Testing on device**: Use the Makefile with a `.env` file containing the path to your device's KOReader plugins folder (`KOREADER_PLUGINS_PATH`): `make install` (production), `make install-test` (test version), `make install-all` (both). These wrap `scripts/copy_to_pocketbook.sh`, which builds the test plugin as a copy of the production one with a different `name` in `_meta.lua`, so both versions can run side by side. Everything the plugin keys itself by follows from that name through `modules/plugin_identity.lua` -- the settings key, the three database filenames, the menu key, the two dispatcher action ids, the two events and the labels a reader sees -- so a new key or database needs nothing added to the script. The derivations are pinned as literals in `spec/plugin_identity_spec.lua`, because for the name "Crossbill" every one of them has to stay byte-identical to what is already on readers' devices.

Two things cannot be derived and the script still does them by hand: the `modules/` directory and the copy of `_meta` the plugin requires are renamed, and everything that requires them rewritten to match. Lua caches a module by name, so a name both copies use means whichever plugin KOReader loads first answers for both, and the production plugin reports the test build's name and version as its own. Two guards run before anything is installed: one refuses a test build that still requires a name the production plugin uses, the other evaluates the built plugin's identity module and refuses a build that still derives the production namespace -- which is what catches an `_meta.lua` edit the rename no longer matches.

**Linting and formatting**: `make lint` runs luacheck (config in `.luacheckrc`), `make format` runs StyLua (config in `.stylua.toml`).

**Unit tests**: `make test` runs busted over `spec/` (config in `.busted`). Specs are named `<module>_spec.lua` and target Lua 5.1, matching the LuaJIT KOReader runs plugins on. Because the plugin's modules `require` KOReader internals that do not exist outside the reader, `spec/support/koreader/` holds thin stand-ins (`logger`, `docsettings`, `ffi/sha2`, `ffi/util`, `ffi/archiver`, `device`, `random`, `json`, `gettext`, the `ui/*` widgets, and — for `main.lua` — `dispatcher`, `datastorage` and the `lua-ljsqlite3` binding). `libs/libkoreader-lfs` hands over the real LuaFileSystem rather than a fake, and the `ffi/util` stand-in does real path and directory work, so the installer's staging and swap are tested against real directories — a swap with its arguments the wrong way round passes a mock and destroys a reader's plugin that `.busted` puts on `package.path` — so plugin sources never need test-only branches. `G_reader_settings` is a global rather than a module; `spec/support/global_settings_fake.lua` installs and restores it around a test. The SQLite binding is deliberately not stubbed into a working database: the modules over a store take it as a dependency, so `spec/support/fake_session_store.lua` and `spec/support/fake_snapshot_store.lua` stand in for the real one, and `SessionTracker` takes its clock the same way so a spec can move it past a gap. When one test needs different behaviour, prefer busted's `stub`/`spy` over growing a stub module.

`make check` runs lint, the formatting check and the tests. Keep `make check` green.

**Releases and the version**: never edit `version` in `crossbill.koplugin/_meta.lua`. The Release workflow owns it (`workflow_dispatch`, pick patch/minor/major): it bumps the line, commits it to main, tags it and publishes the plugin zip. CI fails any pull request whose `_meta.lua` evaluates to a different version than the one at its merge base (`scripts/check_version_unchanged.sh`, which compares the value rather than the text). Every request carries the version as `X-Crossbill-Client: koreader-plugin/<version>`, and the server refuses versions it no longer supports. `_meta.lua` also owns the project URL as `homepage`; the About menu item and the too-old-plugin message both read it from there, so never write that address out a second time. It owns `update_check_url` in the same way: `modules/update/check.lua` asks that address for the newest published release, so pointing the check at a different service is an edit to that one line. The Release workflow also signs the zip with the Ed25519 key in the `CROSSBILL_SIGNING_KEY` secret, publishes the detached signature as `crossbill.koplugin.zip.sig`, and fails if that signature matches no key in `crossbill.koplugin/modules/update/keys.lua` — so a release nobody could install never ships. Generate or rotate the key with `scripts/setup_signing_key.sh`.

**Updating the plugin from the device**: `modules/update/` holds the whole story — `check.lua` asks GitHub what the newest release is, `installer.lua` downloads and swaps it in, `signature.lua` verifies it, and `keys.lua` lists the public keys a release may be signed with. Nothing is installed that is not signed by one of those keys, and every way of being unable to check that refuses just as firmly; the reader is told to install by hand instead. `signature.lua` is the only `ffi.cdef` in the plugin, deliberately, so the rest stays testable — busted runs plain Lua 5.1, where `require("ffi")` fails and the module takes its fail-closed path.

The installer stages the new version as a sibling of the plugin directory and swaps it in with two renames, rather than writing over the plugin in place: a staging directory that fails halfway is thrown away, where a half-overwritten plugin would load and misbehave. It refuses when the archive's top-level directory does not match the plugin directory's name, which is what keeps the side-by-side test build from installing the production plugin over itself.

**No build step required** - Lua files are loaded directly by KOReader.

## Architecture

The plugin follows a modular architecture with dependency injection:

```
main.lua (CrossbillSync)
    ├── BookIdentity    - The client book id and file hash, the only copy of either formula
    ├── Settings        - Configuration persistence via KOReader's G_reader_settings
    ├── Auth            - OAuth token management (login, refresh, caching)
    ├── ApiClient       - HTTP API communication (highlights, sessions, files)
    ├── SessionTracker  - Reading session tracking (over SessionStore)
    ├── SyncService     - Orchestrates sync workflow (uses ApiClient, SessionTracker)
    ├── UI              - KOReader dialogs and menu building
    ├── DigestFormat    - A digest item as title, HTML and plain text; no widgets
    ├── SqliteStore     - One database file: WAL, schema, migrations, statements
    │   ├── SessionStore           - Finished reading sessions
    │   ├── DigestCache            - Chapter digests, kept for offline reading
    │   └── HighlightSnapshotStore - The server highlights a book last applied
    └── update/         - Checking for, verifying and installing a newer plugin
        ├── check.lua       - Asks the release service what the newest version is
        ├── installer.lua   - Downloads, verifies and swaps in a new version
        ├── signature.lua   - Ed25519 verification, the only FFI in the plugin
        └── keys.lua        - Public keys a release may be signed with
```

**Key patterns:**

- `main.lua` is the entry point, extending KOReader's `WidgetContainer`
- All modules use constructor injection: `Module:new(dependencies)`
- Nothing requires `logger` directly. A module takes its logger from `modules/log.lua` -- `local log = Log.forModule("SyncService")` -- and calls `log.dbg`, `log.info`, `log.warn` or `log.err` with the message alone. The prefix is built there as `<display name> <ModuleName>:` (so `Crossbill SyncService:`, and `Crossbill Test SyncService:` in the side-by-side test build), which is why a log prefix is never written out as a literal
- API methods return `code, data, error`; success is `code == 200`, and a `code` of nil means nothing answered at all. The data is whatever the server sent, nil when it sent nothing, and a caller that needs a body checks for one. A 200 whose body would not decode is no usable answer either, so it comes back with a nil code and a message saying which call it was
- A failure a caller acts on rather than merely reports travels as a typed error, never as prose to match on: `modules/upgrade_required.lua` for the server refusing this plugin version, `modules/auth_failed.lua` for credentials the server would not accept. Both carry `__tostring` and `__concat`, so a path that logs or appends the error still works. A plain network error stays a plain string.
- Every ApiClient call goes out through `_authorizedGet`, `_authorizedPost` or `_authorizedMultipart`, so a public method is a payload builder and one call. They share `_sendAuthorized`, which fetches the token and, when the server answers 401, forgets the stored tokens and sends the request once more: a token revoked before its recorded expiry would otherwise fail every call until that expiry passed. `Settings:getApiUrl()` owns the `/api/v1` prefix, so neither ApiClient nor Auth writes it out. The server's 426 refusal is raised as an `UpgradeRequired` error from the three wrappers those helpers send through, caught once in `SyncService:syncBook` and once in `DigestService:getForCurrentChapter`, so no call site has to check for it.
- Network module handles WiFi lifecycle (enable before sync, disable after if we enabled it)
- The SQLite-backed stores -- `session_store`, `digest_cache`,
  `highlight_snapshot_store` -- are each a schema and its queries over a
  `SqliteStore`, which owns the connection, WAL mode, migrations, the
  not-open guard and the logging of anything that fails. Nothing there raises:
  every caller is a KOReader event handler. A bind list that can hold a nil is
  built with `SqliteStore.binds`, because `#` stops at the first one.
- `SessionTracker` and `HighlightSnapshot` take their store as a dependency, so
  their specs run against an in-memory fake rather than the reader's SQLite
  binding

**Data flow:**

1. `BookMetadata` extracts title, author and ISBN from document
2. `HighlightExtractor` reads annotations from memory (preferred) or disk
3. `SyncService` coordinates upload of highlights, sessions, and files
4. `SessionTracker` decides what a session is; `SessionStore` keeps them in
   SQLite (`crossbill_sessions.sqlite3`)

**Book identification:**

`modules/book_identity.lua` owns both hashes, and is the only place either
formula is written:

- `client_book_id`: MD5 hash of "title|author" - used for server-side deduplication
- `book_file_hash`: MD5 hash of file path - used for local session tracking

They live together because the snapshot ledger decides whose highlights it is
looking at by comparing the file hash SyncService computed against the one
SessionTracker stored, so a second copy of either formula that drifts breaks
that silently. BookMetadata, SyncService and SessionTracker all call this
module rather than hashing anything themselves.

## KOReader Integration Points

- Event handlers: `onReaderReady`, `onPageUpdate`, `onSuspend`, `onResume`, `onCloseDocument`, `onExit`
- Menu registration: `addToMainMenu` via `self.ui.menu:registerToMainMenu(self)`
- Settings storage: `G_reader_settings` global
- Document access: `self.ui.document`, `self.ui.annotation`, `self.ui.toc`
