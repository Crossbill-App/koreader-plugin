# KOReader stubs

The plugin runs inside KOReader, so its modules `require` things that only exist
in the reader: `logger`, `docsettings`, `ffi/sha2`, `device`, `random`, `json`,
`gettext`, `ui/event`, `ui/uimanager`, `ui/trapper` and the `ui/widget/*` tree.
`main.lua` adds `dispatcher`, `datastorage`, `ui/widget/container/widgetcontainer`
and, through the three SQLite-backed modules, the `lua-ljsqlite3/init` binding
KOReader bundles. None of that is installable from LuaRocks.

The files in this directory stand in for those modules. `.busted` puts this
directory on `package.path` ahead of everything else, so `require("logger")`
inside `crossbill.koplugin/modules/*.lua` resolves here when running under
busted, and to the real KOReader module on a device. The plugin sources need no
test-only branches as a result.

Stubs are deliberately thin: they implement the slice of the API the plugin
touches, plus a small control surface for specs (`DocSettings.setFixture`,
`DocSettings.reset`, `Device.reset`, `random.setNextUuids`, `Trapper.answer`,
`Dispatcher.reset`). Several are deliberately less capable than the real thing
-- `json` decodes only the one literal the plugin decodes at load time, and
`lua-ljsqlite3` refuses to open a database at all, both erroring rather than
pretending. When a spec needs a module to behave differently for one test,
prefer busted's `stub`/`spy` over growing the stub.

`modules/network` is the plugin's own module rather than KOReader's, so it cannot
be shadowed from here: `crossbill.koplugin` comes first on the path. A spec that
must keep it off the wire seeds `package.loaded` with a fake before requiring the
module under test -- see `spec/api_client_spec.lua` and `spec/main_spec.lua`.
`spec/network_spec.lua` needs the real module, so it seeds fakes for the layer
underneath it instead (LuaSocket, `json` and `ui/network/manager`) and puts them
all back afterwards.

`G_reader_settings` is a global rather than a module, so its fake lives one
level up in `spec/support/global_settings_fake.lua`.

Adding a stub: create the file under the path KOReader's own `require` string
implies (`require("ffi/sha2")` -> `ffi/sha2.lua`) and keep it to the API the
plugin actually calls.
