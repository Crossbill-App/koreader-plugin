# KOReader stubs

The plugin runs inside KOReader, so its modules `require` things that only exist
in the reader: `logger`, `docsettings`, `ffi/sha2` and (for the UI modules) the
whole `ui/widget/*` tree. None of that is installable from LuaRocks.

The files in this directory stand in for those modules. `.busted` puts this
directory on `package.path` ahead of everything else, so `require("logger")`
inside `crossbill.koplugin/modules/*.lua` resolves here when running under
busted, and to the real KOReader module on a device. The plugin sources need no
test-only branches as a result.

Stubs are deliberately thin: they implement the slice of the API the plugin
touches, plus a small control surface for specs (`DocSettings.setFixture`,
`DocSettings.reset`). When a spec needs a module to behave differently for one
test, prefer busted's `stub`/`spy` over growing the stub.

`G_reader_settings` is a global rather than a module, so its fake lives one
level up in `spec/support/global_settings_fake.lua`.

Adding a stub: create the file under the path KOReader's own `require` string
implies (`require("ffi/sha2")` -> `ffi/sha2.lua`) and keep it to the API the
plugin actually calls.
