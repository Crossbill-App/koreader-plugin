<p align="center">

<img width="96" height="96" alt="image" src="https://github.com/user-attachments/assets/6461072f-2265-443b-a018-db7ae26cb42f" />
</p>

# Crossbill KOReader Plugin

Syncs your KOReader highlights to your Crossbill server.

## Installation

1. Copy the `crossbill.koplugin` directory to your KOReader plugins folder:
   - **Device**: `koreader/plugins/`
   - **Desktop**: `.config/koreader/plugins/` (Linux/Mac) or `%APPDATA%\koreader\plugins\` (Windows)

2. Restart KOReader

3. Open any book and go to: Menu → crossbill Sync → Configure Server

4. Enter your Crossbill server host URL (e.g., `http://192.168.1.100:8000`)

## Usage

1. Open a book with highlights
2. Menu → Crossbill Sync → Sync Current Book
3. View your synced highlights on your crossbill server

## Features

- Syncs highlights from the currently open book
- Pulls highlights back from Crossbill, so edits and deletions made in the web app reach the device
- Uploads book epub to the Crossbill
- Uploads reading session data to the Crossbill
- Works with EPUB files
- View the AI generated digest of the current chapter on KOReader

## Pull highlights from Crossbill

Menu → Crossbill → Pull highlights from Crossbill (also bindable to a gesture)
replaces the open book's highlights with the copy held by the server. Crossbill
is the master: highlights you deleted or edited in the web app are deleted or
edited on the device, and highlights made on your other devices appear here.

- Your unsynced highlights are pushed to the server first, so nothing made on
  this device is lost. If that push fails, nothing is replaced.
- Edits to a highlight's note or colour made on different devices are merged by
  the time of the edit: the most recent change wins, whichever device made it.
- Deleting a highlight on the e-reader does not delete it in Crossbill; the next
  pull brings it back. Delete it in Crossbill instead, and that deletion reaches
  every device on its next pull.
- Page bookmarks are kept untouched; only highlights and notes are replaced.
- Highlights the server has no position for, or whose position no longer
  resolves in this copy of the book, are skipped and reported in the summary.
- Before anything is changed, the book's KOReader metadata file is copied to
  `<book>.sdr/metadata.epub.lua.crossbill-<YYYYMMDD-HHMMSS>.bak`. The three
  newest backups are kept.
- Reflowable books (EPUB) only: highlight positions are xpointers, which do not
  apply to fixed-layout formats such as PDF.

## Requirements

- Network connection to your Crossbill server

## Tested devices

While the plugin _should_ work on any device running KOReader, it has been specifically tested on:

- Pocketbook Era

## Server Configuration

The default server URL is `http://localhost:8000`. You'll need to change this to your actual Crossbill server host address.

## Development

Copy `.env.example` to `.env` and set `KOREADER_PLUGINS_PATH` to your device's KOReader plugins folder, then use the Makefile:

```bash
make install       # copy the production plugin to the device
make install-test  # copy the test plugin to the device
make install-all   # copy both
make lint          # luacheck
make format        # stylua
make test          # busted unit tests
make check         # lint + formatting check + tests
make help          # list all targets
```

The test plugin is a renamed copy of the production one with its own settings key and databases, so both can run side by side
with different server configurations. `make install`/`install-test`/`install-all` wrap `scripts/copy_to_pocketbook.sh`, which
can also be called directly with `production`, `test` or `all`.

The same checks can run as a git pre-commit hook via [prek](https://prek.j178.dev):
`uv tool install prek`, then `prek install` in the repo — every commit then runs
stylua and luacheck on the staged Lua files and the busted suite.

Linting, formatting and testing need [luacheck](https://github.com/lunarmodules/luacheck),
[StyLua](https://github.com/JohnnyMorganz/StyLua) and [busted](https://lunarmodules.github.io/busted/);
run `make tools` for install commands.

### Tests

Unit tests live in `spec/` and run under busted, the same framework KOReader itself uses:

```bash
make test                        # the whole suite
busted spec/settings_spec.lua    # one file
busted --filter "ISBN"           # tests whose name matches
```

The plugin's modules `require` things that only exist inside KOReader (`logger`, `docsettings`,
`ffi/sha2`). `spec/support/koreader/` holds thin stand-ins for those, and `.busted` puts that
directory on `package.path`, so the plugin sources need no test-only branches. See
[`spec/support/koreader/README.md`](spec/support/koreader/README.md) before adding a stub.

Tests target Lua 5.1, matching the LuaJIT that KOReader runs plugins on.
