#!/bin/bash
#
# Fail when a branch changes the plugin's version.
#
# Usage: scripts/check_version_unchanged.sh <base-ref> <head-ref>
#
# The Release workflow owns the version line: it bumps it, commits it to main and
# tags the result. A branch that bumps it by hand either collides with that or
# quietly ships a version no release ever made.
#
# What is compared is the version each side *evaluates to*, not the text of the
# line that sets it. A diff of the file can be talked out of noticing a bump --
# a `-diff` attribute makes it binary, a second `version = ...` key in the same
# table changes the answer without touching the first line -- whereas the value
# Lua ends up with is the one the plugin will report to the server.
#
# The comparison is against the merge base rather than the tip of the base
# branch, so a release that landed on main after the branch was cut is not
# mistaken for the branch's own doing.

set -euo pipefail

META_PATH="crossbill.koplugin/_meta.lua"

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <base-ref> <head-ref>" >&2
    exit 2
fi

BASE_REF="$1"
HEAD_REF="$2"

# Any Lua will do -- _meta.lua is a table constructor. Prefer the 5.1 the plugin
# actually runs under where it is installed.
LUA_BIN="${LUA:-}"
if [ -z "$LUA_BIN" ]; then
    for candidate in lua5.1 luajit lua; do
        if command -v "$candidate" >/dev/null 2>&1; then
            LUA_BIN="$candidate"
            break
        fi
    done
fi
if [ -z "$LUA_BIN" ]; then
    echo "Error: no Lua interpreter found (looked for lua5.1, luajit, lua)" >&2
    exit 2
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# _meta.lua asks KOReader for a translator. Standing one in lets the file be
# evaluated outside the reader, and lets an old revision of it be evaluated
# without depending on what the rest of the tree looked like back then.
cat >"$WORKDIR/gettext.lua" <<'LUA'
return function(text)
	return text
end
LUA

# Print the version a revision's _meta.lua evaluates to
# $1 the revision, $2 a name to save the file under
version_at() {
    local revision="$1"
    local name="$2"
    local file="$WORKDIR/$name.lua"

    if ! git show "$revision:$META_PATH" >"$file" 2>/dev/null; then
        return 1
    fi

    CROSSBILL_META="$file" CROSSBILL_SHIM="$WORKDIR" "$LUA_BIN" -e '
        package.path = os.getenv("CROSSBILL_SHIM") .. "/?.lua;" .. package.path
        local ok, meta = pcall(dofile, os.getenv("CROSSBILL_META"))
        if not ok or type(meta) ~= "table" or type(meta.version) ~= "string" then
            os.exit(1)
        end
        io.write(meta.version)
    '
}

MERGE_BASE="$(git merge-base "$BASE_REF" "$HEAD_REF")"

if ! HEAD_VERSION="$(version_at "$HEAD_REF" head)"; then
    echo "Error: $META_PATH does not load, or names no version, at $HEAD_REF." >&2
    exit 1
fi

if ! BASE_VERSION="$(version_at "$MERGE_BASE" base)"; then
    # Nothing to have changed from: this branch is where the file starts.
    echo "$META_PATH is new in this branch; nothing to compare against."
    exit 0
fi

if [ "$BASE_VERSION" != "$HEAD_VERSION" ]; then
    echo "This branch changes the version in $META_PATH: $BASE_VERSION -> $HEAD_VERSION."
    echo "The Release workflow owns this line — never bump it by hand."
    exit 1
fi

echo "Version unchanged since the merge base: $HEAD_VERSION."
