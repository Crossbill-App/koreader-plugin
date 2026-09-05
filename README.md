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

3. Open any EPUB and go to: Menu → Tools → Crossbill → Settings → Configure Server

4. Enter your Crossbill server host URL (e.g., `http://192.168.1.100:8000`)

## Usage

1. Open a book with highlights
2. Menu → Tools → Crossbill → Sync Current Book
3. View your synced highlights on your crossbill server

## Features

- Syncs highlights from the currently open book
- Uploads book epub to the Crossbill
- Uploads reading session data to the Crossbill
- Works with EPUB files only: on a PDF, mobi, fb2 or any other format the plugin
  stays inactive and its menu does not appear
- View the AI generated digest of the current chapter on KOReader

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
make verify-migration LJSQLITE3_DIR=<dir>  # the one-database migration, against real SQLite
make help          # list all targets
```

The test plugin is a renamed copy of the production one with its own settings key and database, so both can run side by side
with different server configurations. `make install`/`install-test`/`install-all` wrap `scripts/copy_to_pocketbook.sh`, which
can also be called directly with `production`, `test` or `all`.

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

One thing busted cannot cover is `modules/legacy_databases`, which carries a reader's rows out of the three databases the
plugin kept before this one and then deletes those files: the specs have no SQLite binding on purpose, so they check the
statements rather than what SQLite makes of them. `scripts/verify_database_migration.lua` runs the whole migration over real
files with real rows, in both the oldest and the last three-file schema. It needs luajit and a directory holding KOReader's
`lua-ljsqlite3` binding:

```bash
make verify-migration LJSQLITE3_DIR=/path/to/koreader/frontend
```
