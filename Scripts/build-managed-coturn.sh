#!/bin/sh
set -eu

# Rebuild the binary and its genuine dSYM as one pair. Ordinary Xcode builds
# use the checked-in pair and do not download or rebuild third-party code.
relay_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
coturn_version=4.17.2
coturn_sha256=645a1beaeeba2684139d9b342d30320ac57a415577b6356dad9df20025cf5315
coturn_url="https://github.com/coturn/coturn/archive/refs/tags/$coturn_version.tar.gz"
openssl_prefix=${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}
libevent_prefix=${LIBEVENT_PREFIX:-$(brew --prefix libevent)}
macos_sdk=$(xcrun --sdk macosx --show-sdk-path)
coturn_work=$(mktemp -d /private/tmp/noctweave-coturn.XXXXXX)
trap 'rm -rf "$coturn_work"' EXIT
trap 'exit 1' HUP INT TERM

# coturn's configure script expands compiler flags without shell quoting.
case "$openssl_prefix$libevent_prefix$macos_sdk" in
    *[[:space:]]*) echo "Dependency and SDK paths must not contain whitespace." >&2; exit 1 ;;
esac

coturn_archive="$coturn_work/coturn.tar.gz"
if [ -n "${COTURN_SOURCE_ARCHIVE:-}" ]; then
    cp "$COTURN_SOURCE_ARCHIVE" "$coturn_archive"
else
    curl --fail --location --proto '=https' --tlsv1.2 "$coturn_url" -o "$coturn_archive"
fi
printf '%s  %s\n' "$coturn_sha256" "$coturn_archive" | shasum -a 256 -c -
tar -xzf "$coturn_archive" -C "$coturn_work"
cd "$coturn_work/coturn-$coturn_version"

env \
    CC="$(xcrun --find clang)" \
    SDKROOT="$macos_sdk" \
    CFLAGS="-arch arm64 -isysroot $macos_sdk -mmacosx-version-min=26.0 -O2 -g -fdebug-prefix-map=$coturn_work=/noctweave/vendor" \
    LDFLAGS="-arch arm64 -isysroot $macos_sdk -mmacosx-version-min=26.0" \
    SSL_CFLAGS="-I$openssl_prefix/include" \
    SSL_LIBS="$openssl_prefix/lib/libssl.a $openssl_prefix/lib/libcrypto.a" \
    EVENT_CFLAGS="-I$libevent_prefix/include" \
    EVENT_LIBS="$libevent_prefix/lib/libevent_core.a $libevent_prefix/lib/libevent_extra.a $libevent_prefix/lib/libevent_openssl.a $libevent_prefix/lib/libevent_pthreads.a $libevent_prefix/lib/libevent.a" \
    TURN_NO_SQLITE=1 TURN_NO_PQ=1 TURN_NO_MYSQL=1 TURN_NO_MONGO=1 TURN_NO_HIREDIS=1 \
    TURN_NO_TLS=1 TURN_NO_DTLS=-DTURN_NO_DTLS TURN_NO_OAUTH=-DTURN_NO_OAUTH \
    TURN_NO_PROMETHEUS=1 TURN_NO_SCTP=1 TURN_NO_SYSTEMD=-DTURN_NO_SYSTEMD \
    ./configure --disable-rpath

# Apple clang invokes dsymutil before deleting the temporary objects from
# coturn's combined compile/link command. Preserve that dSYM before stripping.
make -j "$(sysctl -n hw.logicalcpu)" bin/turnserver
coturn_dsym="bin/turnserver.dSYM"
coturn_dwarf="$coturn_dsym/Contents/Resources/DWARF/turnserver"
test -f "$coturn_dwarf"
xcrun dwarfdump --verify "$coturn_dsym"
xcrun dwarfdump --debug-info "$coturn_dwarf" |
    awk '/DW_TAG_compile_unit/ { found = 1 } END { exit !found }'
test "$(bin/turnserver --version)" = "$coturn_version"

# A distributed helper must not depend on the build machine's Homebrew dylibs.
xcrun otool -L bin/turnserver |
    awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad = 1 } END { exit bad }'

helper_bundle="$relay_root/Noctweave Relay/ManagedCoturn.bundle"
symbol_dir="$relay_root/Symbols"
mkdir -p "$symbol_dir"
install -m 755 bin/turnserver "$helper_bundle/Contents/MacOS/turnserver"
xcrun strip -S -x "$helper_bundle/Contents/MacOS/turnserver"
rm -rf "$symbol_dir/ManagedCoturn.bundle.dSYM"
ditto "$coturn_dsym" "$symbol_dir/ManagedCoturn.bundle.dSYM"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$relay_root/Noctweave Relay/ManagedCoturn.entitlements" "$helper_bundle"

helper_uuid=$(xcrun dwarfdump --uuid "$helper_bundle/Contents/MacOS/turnserver" | awk '/^UUID: / { print $2, $3 }')
symbol_uuid=$(xcrun dwarfdump --uuid "$symbol_dir/ManagedCoturn.bundle.dSYM" | awk '/^UUID: / { print $2, $3 }')
test -n "$helper_uuid"
test "$helper_uuid" = "$symbol_uuid"

{
    printf 'coturn %s\nSource: %s\nSHA-256: %s\n\n' "$coturn_version" "$coturn_url" "$coturn_sha256"
    xcodebuild -version
    printf 'macOS SDK: %s\n' "$(xcrun --sdk macosx --show-sdk-version)"
    "$openssl_prefix/bin/openssl" version
    sed -n '/^#define EVENT__VERSION /p' "$libevent_prefix/include/event2/event-config.h"
    printf '\n'
    xcrun dwarfdump --uuid "$helper_bundle/Contents/MacOS/turnserver" |
        awk '/^UUID: / { print $1, $2, $3 }'
} > "$symbol_dir/ManagedCoturn-build.txt"

echo "Rebuilt ManagedCoturn.bundle and Symbols/ManagedCoturn.bundle.dSYM."
