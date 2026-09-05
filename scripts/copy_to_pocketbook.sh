#!/bin/bash
#
# Copy the Crossbill plugin to a connected device's KOReader plugins folder.
#
# Usage: scripts/copy_to_pocketbook.sh [production|test|all]
#
#   production  Install crossbill.koplugin only
#   test        Install crossbill-test.koplugin only (a renamed copy that keeps
#               its own settings and databases, so it can run alongside production)
#   all         Install both (default)
#
# The test build is a copy of the production plugin with its name changed in
# _meta.lua. Everything else that has to differ -- the settings key, the three
# database filenames, the menu key, the two dispatcher action ids, the two
# events and the labels a reader sees -- is derived from that name by
# modules/plugin_identity.lua, so renaming the plugin renames all of it. Only
# two things cannot be derived and are still done here: the modules/ directory
# and the copy of _meta the plugin requires, both of which are renamed because
# Lua caches a module by name.
#
# The destination is read from KOREADER_PLUGINS_PATH in the repository's .env file.

set -euo pipefail

MODE="${1:-all}"
case "$MODE" in
    production | test | all) ;;
    *)
        echo "Error: unknown mode '$MODE'"
        echo "Usage: $0 [production|test|all]"
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Scratch directory used to build the test plugin; removed on exit
TEST_BUILD_DIR=""
cleanup() {
    if [ -n "$TEST_BUILD_DIR" ]; then
        rm -rf "$TEST_BUILD_DIR"
    fi
}
trap cleanup EXIT

# Source the .env file
if [ -f "$REPO_ROOT/.env" ]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
else
    echo "Error: .env file not found in $REPO_ROOT"
    echo "Please copy .env.example to .env and configure it"
    exit 1
fi

# Check if the target path is set
if [ -z "${KOREADER_PLUGINS_PATH:-}" ]; then
    echo "Error: KOREADER_PLUGINS_PATH is not set in .env"
    exit 1
fi

if [ ! -d "$KOREADER_PLUGINS_PATH" ]; then
    echo "Error: KOREADER_PLUGINS_PATH does not exist: $KOREADER_PLUGINS_PATH"
    echo "Is the device connected and mounted?"
    exit 1
fi

install_production() {
    echo "Copying production plugin..."
    # Remove the old plugin first to ensure a clean copy (cp -R merges, doesn't replace)
    rm -rf "$KOREADER_PLUGINS_PATH/crossbill.koplugin"
    cp -R "$REPO_ROOT/crossbill.koplugin" "$KOREADER_PLUGINS_PATH/"
}

install_test() {
    echo "Creating test plugin..."
    # Build the test plugin in a temporary directory
    TEST_BUILD_DIR=$(mktemp -d)

    local test_dir="$TEST_BUILD_DIR/crossbill-test.koplugin"
    cp -R "$REPO_ROOT/crossbill.koplugin" "$test_dir"

    # Modify _meta.lua for test version
    sed -i 's/name = "Crossbill"/name = "Crossbill Test"/' "$test_dir/_meta.lua"
    sed -i 's/fullname = _("Crossbill Sync")/fullname = _("Crossbill Test Sync")/' "$test_dir/_meta.lua"
    sed -i 's/description = _(\[\[Syncs your highlights to Crossbill server for editing and management.\]\])/description = _([[TEST VERSION - Syncs your highlights to Crossbill server for editing and management.]])/' "$test_dir/_meta.lua"

    # Rename modules directory to avoid Lua require cache conflicts
    # (Lua caches "modules/ui" globally, so both plugins would share the same module)
    mv "$test_dir/modules" "$test_dir/test_modules"

    # Same for _meta, which four modules require and which KOReader also reads
    # by path for the plugin's own name and version. The file has to keep its
    # name for KOReader, so the copy the plugin requires gets a new one: whoever
    # loaded first was otherwise answering for both plugins, and the production
    # plugin would report the test build's name and version as its own.
    cp "$test_dir/_meta.lua" "$test_dir/test_meta.lua"

    # Update require paths to use the renamed modules and meta (in main.lua and
    # all module files)
    find "$test_dir" -name "*.lua" -exec sed -i \
        -e 's|require("modules/|require("test_modules/|g' \
        -e 's|require("_meta")|require("test_meta")|g' {} \;

    # Nothing in the test build may require a name the production plugin also
    # uses. Lua caches a module by name, so a shared name means whichever
    # plugin KOReader loads first answers for both -- which is not an error
    # anywhere, just the wrong plugin's answer. Checked rather than trusted,
    # because the renames above have to be remembered every time a module or a
    # top-level file is added, and forgetting one looks like a plugin bug.
    local shared=""
    while read -r module; do
        if [ -f "$REPO_ROOT/crossbill.koplugin/$module.lua" ]; then
            shared="$shared  $module"$'\n'
        fi
    done < <(grep -rhoE 'require\("[^"]+"\)' "$test_dir" | sed -E 's/require\("(.*)"\)/\1/' | sort -u)

    if [ -n "$shared" ]; then
        echo "Error: the test plugin requires names the production plugin also uses:"
        printf '%s' "$shared"
        echo "Both would share one copy of each. Rename them in $0."
        exit 1
    fi

    # The whole test identity now hangs off one string, so the one thing left to
    # check is that the string actually changed. A rewrite of _meta.lua that the
    # sed above no longer matches -- a reformatted table, a renamed plugin --
    # would leave the test build deriving the production namespace and quietly
    # reading and writing the reader's own settings and databases.
    check_identity() {
        local lua
        for lua in luajit lua5.1 lua; do
            if command -v "$lua" >/dev/null 2>&1; then
                break
            fi
            lua=""
        done

        if [ -z "$lua" ]; then
            echo "Warning: no Lua interpreter found; not checking the test build's identity."
            return 0
        fi

        # _meta.lua asks for KOReader's gettext, which is not here; the plugin's
        # name needs no translating, so a pass-through stands in for it.
        local namespace
        # The directory travels in the environment because an interpreter given
        # -e reads a trailing argument as a script to run, not as an argument.
        namespace=$(TEST_PLUGIN_DIR="$test_dir" "$lua" -e '
            package.path = os.getenv("TEST_PLUGIN_DIR") .. "/?.lua;" .. package.path
            package.preload["gettext"] = function()
                return function(text) return text end
            end
            io.write(require("test_modules/plugin_identity").namespace)
        ')

        if [ "$namespace" = "crossbill" ]; then
            echo "Error: the test plugin derives the production namespace '$namespace'."
            echo "It would share the production plugin's settings and databases."
            echo "The name in _meta.lua was not renamed; check the seds in $0."
            exit 1
        fi

        echo "Test plugin identity: $namespace"
    }
    check_identity

    # Copy test plugin to destination
    rm -rf "$KOREADER_PLUGINS_PATH/crossbill-test.koplugin"
    cp -R "$test_dir" "$KOREADER_PLUGINS_PATH/"
}

install_patch() {
    echo "Installing menu-position user patch..."
    # Patches live in koreader/patches/, a sibling of the plugins directory
    local koreader_dir
    koreader_dir="$(dirname "$KOREADER_PLUGINS_PATH")"
    mkdir -p "$koreader_dir/patches"
    cp "$REPO_ROOT/patches/2-crossbill-menu-position.lua" "$koreader_dir/patches/"
}

case "$MODE" in
    production)
        install_production
        ;;
    test)
        install_test
        ;;
    all)
        install_production
        install_test
        ;;
esac

install_patch

echo "Done! Installed: $MODE."
