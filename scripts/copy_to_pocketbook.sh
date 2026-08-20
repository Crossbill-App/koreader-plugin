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

    # Modify main.lua for test version
    # Change the class name
    sed -i 's/name = "Crossbill"/name = "Crossbill Test"/' "$test_dir/main.lua"
    # Change the menu key to avoid conflicts with production
    sed -i 's/menu_items\.crossbill_sync/menu_items.crossbill_test_sync/g' "$test_dir/main.lua"
    # Rename dispatcher action ids and events so gestures don't trigger both versions
    sed -i \
        -e 's/crossbill_sync_current_book/crossbill_test_sync_current_book/g' \
        -e 's/crossbill_show_chapter_summary/crossbill_test_show_chapter_summary/g' \
        -e 's/CrossbillSyncCurrentBook/CrossbillTestSyncCurrentBook/g' \
        -e 's/CrossbillShowChapterDigest/CrossbillTestShowChapterDigest/g' \
        -e 's/Sync current book with Crossbill/Sync current book with Crossbill Test/' \
        -e 's/Crossbill chapter digest/Crossbill Test chapter digest/' \
        "$test_dir/main.lua"
    # Update require paths to use renamed modules directory (in main.lua and all module files)
    find "$test_dir" -name "*.lua" -exec sed -i 's|require("modules/|require("test_modules/|g' {} \;

    # Modify test_modules/settings.lua for test version
    # Change settings key to separate from production version
    sed -i 's/crossbill_sync/crossbill_test_sync/g' "$test_dir/test_modules/settings.lua"

    # Modify test_modules/ui.lua for test version
    # Change menu text
    sed -i 's/_("Crossbill")/_("Crossbill Test")/g' "$test_dir/test_modules/ui.lua"

    # Modify test_modules/sessiontracker.lua for test version
    # Change database filename to avoid conflicts with production
    sed -i 's/crossbill_sessions\.sqlite3/test_crossbill_sessions.sqlite3/g' "$test_dir/test_modules/sessiontracker.lua"

    # Modify test_modules/digest_cache.lua for test version
    # Change database filename to avoid conflicts with production
    sed -i 's/crossbill_digests\.sqlite3/test_crossbill_digests.sqlite3/g' "$test_dir/test_modules/digest_cache.lua"

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
