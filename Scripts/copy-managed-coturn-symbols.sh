#!/bin/sh
set -eu

# Keep the prebuilt helper's symbols outside the app, where Xcode collects
# dSYMs for an archive. Never manufacture symbols from the stripped helper.
: "${SRCROOT:?Run this script from the Xcode build phase}"
: "${TARGET_BUILD_DIR:?Missing Xcode target build directory}"
: "${CONTENTS_FOLDER_PATH:?Missing Xcode app contents path}"
: "${DWARF_DSYM_FOLDER_PATH:?Missing Xcode symbol output directory}"

symbols="$SRCROOT/Symbols/ManagedCoturn.bundle.dSYM"
dwarf="$symbols/Contents/Resources/DWARF/turnserver"
helper="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/ManagedCoturn.bundle/Contents/MacOS/turnserver"
destination="$DWARF_DSYM_FOLDER_PATH/ManagedCoturn.bundle.dSYM"

fail() {
    echo "error: ManagedCoturn symbols: $*" >&2
    exit 1
}

[ -f "$dwarf" ] || fail "missing $dwarf. Run Scripts/build-managed-coturn.sh."
[ -f "$helper" ] || fail "the embedded turnserver executable is missing."

uuid_set() {
    /usr/bin/xcrun dwarfdump --uuid "$1" |
        /usr/bin/awk '/^UUID: / { print $2, $3 }' |
        /usr/bin/sort
}

helper_uuids=$(uuid_set "$helper")
symbol_uuids=$(uuid_set "$dwarf")
[ -n "$helper_uuids" ] || fail "could not read the helper UUID."
[ -n "$symbol_uuids" ] || fail "could not read the dSYM UUID."
[ "$helper_uuids" = "$symbol_uuids" ] ||
    fail "the helper and dSYM UUIDs differ. Rebuild and retain them together with Scripts/build-managed-coturn.sh."

/usr/bin/xcrun dwarfdump --debug-info "$dwarf" |
    /usr/bin/awk '/DW_TAG_compile_unit/ { found = 1 } END { exit !found }' ||
    fail "the dSYM contains no source debug information. Rebuild the helper with debug symbols."

# Copy only declared files. ditto creates random temporary siblings, which
# Xcode's script sandbox correctly rejects as undeclared outputs.
/bin/mkdir -p "$destination/Contents/Resources/DWARF" "$destination/Contents/Resources/Relocations/aarch64"
/bin/cp -fX "$symbols/Contents/Info.plist" "$destination/Contents/Info.plist"
/bin/cp -fX "$dwarf" "$destination/Contents/Resources/DWARF/turnserver"
/bin/cp -fX "$symbols/Contents/Resources/Relocations/aarch64/turnserver.yml" "$destination/Contents/Resources/Relocations/aarch64/turnserver.yml"
echo "ManagedCoturn symbols included: $helper_uuids"
