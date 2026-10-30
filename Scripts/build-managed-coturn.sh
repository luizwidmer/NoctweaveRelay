#!/bin/sh
set -eu

# Rebuild the binary and its genuine dSYM as one pair. Ordinary Xcode builds
# use the checked-in pair and do not download or rebuild third-party code.
relay_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
coturn_version=4.18.0
coturn_sha256=28d55294ac596fbd129b293a85e7bb1c5dc4bd15b7fb55c500f355149e5f4e28
openssl_version=3.5.9
libevent_version=2.1.13-stable
coturn_url="https://github.com/coturn/coturn/archive/refs/tags/$coturn_version.tar.gz"
openssl_prefix=${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}
libevent_prefix=${LIBEVENT_PREFIX:-$(brew --prefix libevent)}
openssl_license=${OPENSSL_LICENSE_FILE:-$openssl_prefix/LICENSE.txt}
libevent_license=${LIBEVENT_LICENSE_FILE:-$libevent_prefix/LICENSE}
macos_sdk=$(xcrun --sdk macosx --show-sdk-path)
coturn_work=$(mktemp -d /private/tmp/noctweave-coturn.XXXXXX)
stage_root=
restore_needed=0
cleanup() {
    status=$?
    trap - EXIT
    trap '' HUP INT TERM
    rollback_failed=0
    if [ "$restore_needed" -eq 1 ]; then
        backup="$stage_root/backup"
        if [ -d "$backup/ManagedCoturn.bundle" ]; then
            if ! rm -rf "$relay_root/Noctweave Relay/ManagedCoturn.bundle" ||
               ! mv "$backup/ManagedCoturn.bundle" "$relay_root/Noctweave Relay/ManagedCoturn.bundle"; then
                echo "Failed to restore the previous coturn helper bundle." >&2
                rollback_failed=1
            fi
        fi
        if [ -d "$backup/ManagedCoturn.bundle.dSYM" ]; then
            if ! rm -rf "$relay_root/Symbols/ManagedCoturn.bundle.dSYM" ||
               ! mv "$backup/ManagedCoturn.bundle.dSYM" "$relay_root/Symbols/ManagedCoturn.bundle.dSYM"; then
                echo "Failed to restore the previous coturn symbols." >&2
                rollback_failed=1
            fi
        fi
        if [ -f "$backup/ManagedCoturn-build.txt" ]; then
            if ! mv "$backup/ManagedCoturn-build.txt" "$relay_root/Symbols/ManagedCoturn-build.txt"; then
                echo "Failed to restore the previous coturn build record." >&2
                rollback_failed=1
            fi
        fi
    fi
    if [ "$rollback_failed" -eq 1 ]; then
        echo "Previous coturn files remain in $stage_root/backup; preserve them for recovery." >&2
        stage_root=
        status=1
    fi
    if [ -n "$stage_root" ] && ! rm -rf "$stage_root"; then status=1; fi
    if ! rm -rf "$coturn_work"; then status=1; fi
    exit "$status"
}
trap 'cleanup' EXIT
trap 'exit 1' HUP INT TERM

# coturn's configure script expands compiler flags without shell quoting.
case "$openssl_prefix$libevent_prefix$macos_sdk" in
    *[[:space:]]*) echo "Dependency and SDK paths must not contain whitespace." >&2; exit 1 ;;
esac
test "$("$openssl_prefix/bin/openssl" version | awk '{ print $2 }')" = "$openssl_version" || {
    echo "Managed coturn requires OpenSSL $openssl_version; set OPENSSL_PREFIX to an audited build." >&2
    exit 1
}
grep -Fq "#define EVENT__VERSION \"$libevent_version\"" "$libevent_prefix/include/event2/event-config.h" || {
    echo "Managed coturn requires libevent $libevent_version." >&2
    exit 1
}
test -f "$openssl_license"
test -f "$libevent_license"

coturn_archive="$coturn_work/coturn.tar.gz"
if [ -n "${COTURN_SOURCE_ARCHIVE:-}" ]; then
    cp "$COTURN_SOURCE_ARCHIVE" "$coturn_archive"
else
    curl --fail --location --proto '=https' --tlsv1.2 "$coturn_url" -o "$coturn_archive"
fi
printf '%s  %s\n' "$coturn_sha256" "$coturn_archive" | shasum -a 256 -c -
tar -xzf "$coturn_archive" -C "$coturn_work"
cd "$coturn_work/coturn-$coturn_version"

# Upstream configure prefers the shared /var/tmp even when invoked inside an
# isolated source tree. Keep its compiler probes in this audited work directory.
grep -Fq 'TMPDIR="/var/tmp"' configure
sed -i '' 's|TMPDIR="/var/tmp"|TMPDIR="."|' configure

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
build_jobs=$(sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')
make -j "$build_jobs" bin/turnserver
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
stage_root=$(mktemp -d "$relay_root/.managed-coturn-stage.XXXXXX")
staged_bundle="$stage_root/ManagedCoturn.bundle"
staged_dsym="$stage_root/ManagedCoturn.bundle.dSYM"
staged_record="$stage_root/ManagedCoturn-build.txt"
ditto "$helper_bundle" "$staged_bundle"
install -m 755 bin/turnserver "$staged_bundle/Contents/MacOS/turnserver"
xcrun strip -S -x "$staged_bundle/Contents/MacOS/turnserver"
install -m 644 "$openssl_license" "$staged_bundle/Contents/Resources/OpenSSL-LICENSE.txt"
install -m 644 "$libevent_license" "$staged_bundle/Contents/Resources/Libevent-LICENSE.txt"
ditto "$coturn_dsym" "$staged_dsym"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements "$relay_root/Noctweave Relay/ManagedCoturn.entitlements" "$staged_bundle"
codesign --verify --deep --strict "$staged_bundle"

helper_uuid=$(xcrun dwarfdump --uuid "$staged_bundle/Contents/MacOS/turnserver" | awk '/^UUID: / { print $2, $3 }')
symbol_uuid=$(xcrun dwarfdump --uuid "$staged_dsym" | awk '/^UUID: / { print $2, $3 }')
test -n "$helper_uuid"
test "$helper_uuid" = "$symbol_uuid"

{
    printf 'coturn %s\nSource: %s\nSHA-256: %s\n\n' "$coturn_version" "$coturn_url" "$coturn_sha256"
    xcodebuild -version
    printf 'macOS SDK: %s\n' "$(xcrun --sdk macosx --show-sdk-version)"
    "$openssl_prefix/bin/openssl" version
    sed -n '/^#define EVENT__VERSION /p' "$libevent_prefix/include/event2/event-config.h"
    printf '\n'
    xcrun dwarfdump --uuid "$staged_bundle/Contents/MacOS/turnserver" |
        awk '/^UUID: / { print $1, $2, $3 }'
} > "$staged_record"

# Finish every signing and UUID check before replacing tracked release inputs.
# Keep the previous pair until all three staged outputs have been installed.
for directory in "$relay_root/Noctweave Relay" "$symbol_dir" "$helper_bundle"; do
    if [ ! -d "$directory" ] || [ -L "$directory" ] ||
       [ "$(stat -f %d "$directory")" != "$(stat -f %d "$stage_root")" ]; then
        echo "Managed coturn outputs must be real directories on the staging filesystem: $directory" >&2
        exit 1
    fi
done
mkdir "$stage_root/backup"
restore_needed=1
mv "$helper_bundle" "$stage_root/backup/ManagedCoturn.bundle"
mv "$symbol_dir/ManagedCoturn.bundle.dSYM" "$stage_root/backup/ManagedCoturn.bundle.dSYM"
mv "$symbol_dir/ManagedCoturn-build.txt" "$stage_root/backup/ManagedCoturn-build.txt"
mv "$staged_bundle" "$helper_bundle"
mv "$staged_dsym" "$symbol_dir/ManagedCoturn.bundle.dSYM"
mv "$staged_record" "$symbol_dir/ManagedCoturn-build.txt"
restore_needed=0

echo "Rebuilt ManagedCoturn.bundle and Symbols/ManagedCoturn.bundle.dSYM."
