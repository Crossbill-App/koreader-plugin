--[[
Trusted Release Keys for Crossbill Sync

The public halves of the keys a release may be signed with. An archive whose
signature matches none of these is not installed, whatever else is true of it.

A list rather than a single key, so a key can be replaced without stranding
anyone: add the new key here and publish a release signed with the old one, so
readers pick up the new key before it is ever used to sign. Only once nobody
could plausibly still be running a plugin that predates that release does the
old key come out. Removing a key early is what leaves readers unable to update.

The keys are public. They are in the repository because that is where they have
to be to mean anything: a key fetched over the network proves nothing about the
archive fetched over the same network.

Generate the pair with `scripts/setup_signing_key.sh`, which prints the hex to
paste here.
]]

return {
	-- From version 0.14.0
	"a3825e05b1c7a0a61d49880584d433f6f441af4bb3730e86165dce9691a13a60",
}
