# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a KOReader plugin (Lua) that syncs book highlights and reading sessions to a Crossbill server. The plugin is installed by copying the `crossbill.koplugin` directory to KOReader's plugins folder.

## Development

**Testing on device**: Use the Makefile with a `.env` file containing the path to your device's KOReader plugins folder (`KOREADER_PLUGINS_PATH`): `make install` (production), `make install-test` (test version), `make install-all` (both). These wrap `scripts/copy_to_pocketbook.sh`, which builds the test plugin as a copy of the production one with a different `name` in `_meta.lua`, so both versions can run side by side. Everything the plugin keys itself by follows from that name through `modules/plugin_identity.lua` -- the settings key, the database filename, the menu key, the two dispatcher action ids, the two events and the labels a reader sees -- so a new key needs nothing added to the script. The derivations are pinned as literals in `spec/plugin_identity_spec.lua`, because for the name "Crossbill" every one of them has to stay byte-identical to what is already on readers' devices.

Two things cannot be derived and the script still does them by hand: the `modules/` directory and the copy of `_meta` the plugin requires are renamed, and everything that requires them rewritten to match. Lua caches a module by name, so a name both copies use means whichever plugin KOReader loads first answers for both, and the production plugin reports the test build's name and version as its own. Two guards run before anything is installed: one refuses a test build that still requires a name the production plugin uses, the other evaluates the built plugin's identity module and refuses a build that still derives the production namespace -- which is what catches an `_meta.lua` edit the rename no longer matches.

**Linting and formatting**: `make lint` runs luacheck (config in `.luacheckrc`), `make format` runs StyLua (config in `.stylua.toml`).

**Unit tests**: `make test` runs busted over `spec/` (config in `.busted`). Specs are named `<module>_spec.lua` and target Lua 5.1, matching the LuaJIT KOReader runs plugins on. Because the plugin's modules `require` KOReader internals that do not exist outside the reader, `spec/support/koreader/` holds thin stand-ins (`logger`, `docsettings`, `ffi/sha2`, `ffi/util`, `ffi/archiver`, `device`, `random`, `json`, `gettext`, the `ui/*` widgets, and — for `main.lua` — `dispatcher`, `datastorage` and the `lua-ljsqlite3` binding). `libs/libkoreader-lfs` hands over the real LuaFileSystem rather than a fake, and the `ffi/util` stand-in does real path and directory work, so the installer's staging and swap are tested against real directories — a swap with its arguments the wrong way round passes a mock and destroys a reader's plugin that `.busted` puts on `package.path` — so plugin sources never need test-only branches. `G_reader_settings` is a global rather than a module; `spec/support/global_settings_fake.lua` installs and restores it around a test. The SQLite binding is deliberately not stubbed into a working database: the modules over a store take it as a dependency, so `spec/support/fake_session_store.lua` and `spec/support/fake_snapshot_store.lua` stand in for the real one, and `SessionTracker` takes its clock the same way so a spec can move it past a gap. When one test needs different behaviour, prefer busted's `stub`/`spy` over growing a stub module.

`make check` runs lint, the formatting check and the tests. Keep `make check` green.

**Verifying the database migration**: `make verify-migration LJSQLITE3_DIR=<dir>` runs `scripts/verify_database_migration.lua`, which does the one thing busted cannot. `modules/legacy_databases` moves a reader's reading history and highlight ledger out of the three databases the plugin used to keep and then deletes those files, and the SQLite binding is deliberately not stubbed, so `spec/legacy_databases_spec.lua` checks the statements and the decisions rather than what SQLite makes of them. The script builds both the oldest schemas and the last three-file ones with real rows in WAL mode, migrates them for real and checks what landed. It needs luajit and a directory holding KOReader's `lua-ljsqlite3` binding; run it after touching that module or any of the three schemas.

**Releases and the version**: never edit `version` in `crossbill.koplugin/_meta.lua`. The Release workflow owns it (`workflow_dispatch`, pick patch/minor/major): it bumps the line, commits it to main, tags it and publishes the plugin zip. CI fails any pull request whose `_meta.lua` evaluates to a different version than the one at its merge base (`scripts/check_version_unchanged.sh`, which compares the value rather than the text). Every request carries the version as `X-Crossbill-Client: koreader-plugin/<version>`, and the server refuses versions it no longer supports. `_meta.lua` also owns the project URL as `homepage`; the About menu item and the too-old-plugin message both read it from there, so never write that address out a second time. It owns `update_check_url` in the same way: `modules/update/check.lua` asks that address for the newest published release, so pointing the check at a different service is an edit to that one line. The Release workflow also signs the zip with the Ed25519 key in the `CROSSBILL_SIGNING_KEY` secret, publishes the detached signature as `crossbill.koplugin.zip.sig`, and fails if that signature matches no key in `crossbill.koplugin/modules/update/keys.lua` — so a release nobody could install never ships. Generate or rotate the key with `scripts/setup_signing_key.sh`.

**Updating the plugin from the device**: `modules/update/` holds the whole story — `check.lua` asks GitHub what the newest release is, `installer.lua` downloads and swaps it in, `signature.lua` verifies it, and `keys.lua` lists the public keys a release may be signed with. Nothing is installed that is not signed by one of those keys, and every way of being unable to check that refuses just as firmly; the reader is told to install by hand instead. `signature.lua` is the only `ffi.cdef` in the plugin, deliberately, so the rest stays testable — busted runs plain Lua 5.1, where `require("ffi")` fails and the module takes its fail-closed path.

The installer stages the new version as a sibling of the plugin directory and swaps it in with two renames, rather than writing over the plugin in place: a staging directory that fails halfway is thrown away, where a half-overwritten plugin would load and misbehave. It refuses when the archive's top-level directory does not match the plugin directory's name, which is what keeps the side-by-side test build from installing the production plugin over itself.

**No build step required** - Lua files are loaded directly by KOReader.

## Architecture

The plugin follows a modular architecture with dependency injection. The
modules are grouped below by the flow they belong to rather than by the order
`main.lua` happens to build them: the push, the pull, the digest, the updater,
and the pieces every flow leans on.

```
main.lua (CrossbillSync) - KOReader event handlers, the menu, and the wiring of everything below

The push -- highlights and sessions out
    ├── BookMetadata       - Title, author, ISBN, language and page count off the document
    ├── HighlightExtractor - Highlights from ReaderAnnotation's memory, or the sidecar on disk
    ├── SessionTracker     - Decides what a reading session is and where the reader got to
    ├── SessionStore       - Finished sessions as rows, and the two queries the sync needs
    ├── SyncService        - Orders the sync: the book, the EPUB, the push, the pull, sessions, digests
    ├── ApiClient          - Every server call, answering `code, data, error`
    └── Auth               - Login, refresh and token caching

The pull -- the server's highlights back, and the ledger that makes it safe
    ├── HighlightImporter      - Rebuilds the book's highlights from the server's copy
    ├── HighlightSnapshot      - Per book, the server highlights this file last applied
    ├── HighlightSnapshotStore - Those rows in SQLite: the schema and the queries
    └── NoteEdits              - Stamps notes edited since the last sync, which KOReader does not

The chapter digest
    ├── DigestService - Fetches, caches and matches the current chapter to a digest
    ├── DigestCache   - Digests in SQLite, so a chapter can be read offline
    ├── DigestFormat  - A digest item as title, HTML and plain text; no widgets
    └── DigestViewer  - The scrollable HTML dialog that shows one; no spec, by design

update/ -- checking for, verifying and installing a newer plugin
    ├── check.lua     - Asks the release service what the newest version is
    ├── installer.lua - Downloads, verifies and swaps in a new version
    ├── signature.lua - Ed25519 verification, the only FFI in the plugin
    └── keys.lua      - Public keys a release may be signed with

Shared by all of them
    ├── Settings        - Configuration persistence via KOReader's G_reader_settings
    ├── Network         - HTTP/HTTPS requests and the WiFi lifecycle
    ├── Log             - A logger bound to one module's name; the only caller of `logger`
    ├── PluginIdentity  - Every string the plugin keys itself by, derived from its name
    ├── DocumentSupport - Whether the open document is an EPUB, and so the plugin's business
    ├── DeviceIdentity  - A stable id for this device, shared by sessions and highlights
    ├── BookIdentity    - The client book id and file hash, the only copy of either formula
    ├── TitleMatch      - How a chapter title is normalized before it is compared
    ├── UpgradeRequired - Typed error: the server refuses this plugin version
    ├── AuthFailed      - Typed error: credentials the server would not accept
    ├── SqliteStore     - The one database file: WAL, schemas, migrations, statements
    ├── LegacyDatabases - Carries the three databases the plugin used to keep into that one, then deletes them
    └── UI              - KOReader dialogs and menu building
```

**Key patterns:**

- `main.lua` is the entry point, extending KOReader's `WidgetContainer`
- All modules use constructor injection: `Module:new(dependencies)`
- Nothing but `modules/log.lua` requires `logger` directly. A module takes its logger from `modules/log.lua` -- `local log = Log.forModule("SyncService")` -- and calls `log.dbg`, `log.info`, `log.warn` or `log.err` with the message alone. The prefix is built there as `<display name> <ModuleName>:` (so `Crossbill SyncService:`, and `Crossbill Test SyncService:` in the side-by-side test build), which is why a log prefix is never written out as a literal
- API methods return `code, data, error`; success is `code == 200`, and a `code` of nil means nothing answered at all. The data is whatever the server sent, nil when it sent nothing, and a caller that needs a body checks for one. A 200 whose body would not decode is no usable answer either, so it comes back with a nil code and a message saying which call it was
- A failure a caller acts on rather than merely reports travels as a typed error, never as prose to match on: `modules/upgrade_required.lua` for the server refusing this plugin version, `modules/auth_failed.lua` for credentials the server would not accept. Both carry `__tostring` and `__concat`, so a path that logs or appends the error still works. A plain network error stays a plain string.
- Every ApiClient call goes out through `_authorizedGet`, `_authorizedPost` or `_authorizedMultipart`, so a public method is a payload builder and one call. They share `_sendAuthorized`, which fetches the token and, when the server answers 401, forgets the stored tokens and sends the request once more: a token revoked before its recorded expiry would otherwise fail every call until that expiry passed. `Settings:getApiUrl()` owns the `/api/v1` prefix, so neither ApiClient nor Auth writes it out. The server's 426 refusal is raised as an `UpgradeRequired` error from the three wrappers those helpers send through, caught once in `SyncService:syncBook` and once in `DigestService:getForCurrentChapter`, so no call site has to check for it.
- Network module handles WiFi lifecycle (enable before sync, disable after if we enabled it)
- There is one database file, `crossbill.sqlite3` in KOReader's settings
  directory (`crossbill_test.sqlite3` in the side-by-side test build, the name
  coming from `modules/plugin_identity.lua`). `main.lua` opens it as a
  `SqliteStore` and hands that to the three stores over it -- `session_store`,
  `digest_cache` and `highlight_snapshot_store` -- each of which is a schema and
  its queries, owning its own tables and asking `ensureSchema` for them at
  startup. The `SqliteStore` owns the connection, WAL mode, migrations, the
  not-open guard and the logging of anything that fails, and `main.lua` closes
  it on exit; a store never closes what it did not open. On the first open
  after the update that made the three files one, `modules/legacy_databases`
  absorbs whatever a reader still has in `<namespace>_sessions.sqlite3` and
  `<namespace>_highlights.sqlite3`, counts what arrived and deletes the old
  files, sidecars and all; `<namespace>_digests.sqlite3` is a cache and is only
  deleted. A copy that does not add up leaves its file where it was, and the
  next open tries again. Nothing there raises either:
  every caller is a KOReader event handler. A bind list that can hold a nil is
  built with `SqliteStore.binds`, because `#` stops at the first one.
- `SessionTracker` and `HighlightSnapshot` take their store as a dependency, so
  their specs run against an in-memory fake rather than the reader's SQLite
  binding

**Data flow:**

A sync is one ordered walk through `SyncService:syncBook`, and it is both a
push and a pull:

1. `BookMetadata` extracts title, author and ISBN from the document, and
   `BookIdentity` hashes them into the client book id the server knows the book by
2. `SyncService` asks the server for that book, creates it when it is new, and
   uploads the EPUB the server has no copy of
3. `NoteEdits` stamps the notes edited since the last sync, then
   `HighlightExtractor` reads the annotations from memory (preferred) or disk,
   and the push carries them together with what `HighlightSnapshot` says was
   deleted on this device
4. The server's copy comes back: `HighlightImporter` rebuilds the book's
   highlights from it, and `HighlightSnapshot` records what was placed, so the
   next sync can tell a deletion from a highlight that was never here
5. `SessionTracker` decides what a session is; `SessionStore` keeps them in the
   plugin's database until the same sync uploads them
6. `DigestService` refreshes the book's chapter digests into `DigestCache`,
   which is what the digest menu item and gesture read from -- including offline

Steps 4 and 6 are best-effort: they are run through `SyncService:_bookkeeping`
and a failure is logged rather than failing the sync. Only the server's refusal
to serve this plugin version travels out of them.

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
