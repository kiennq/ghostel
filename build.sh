#!/usr/bin/env bash
# Build ghostel and its vendored dependencies.
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f vendor/ghostty/build.zig ]; then
    echo "Initializing ghostty submodule..."
    git -c url."https://github.com/".insteadOf=git@github.com: \
        submodule update --init vendor/ghostty
fi

case "${OS:-$(uname -s)}" in
    Windows_NT|MINGW*|MSYS*|CYGWIN*)
        STATIC_LIB_EXT=".lib"
        MODULE_EXT=".dll"
        TARGET_ARGS=(-Dtarget=x86_64-windows-gnu)
        ;;
    Darwin)
        STATIC_LIB_EXT=".a"
        MODULE_EXT=".dylib"
        TARGET_ARGS=()
        ;;
    *)
        STATIC_LIB_EXT=".a"
        MODULE_EXT=".so"
        TARGET_ARGS=()
        ;;
esac

ZIG_CMD="${ZIG:-zig}"

echo "Building libghostty-vt..."
(cd vendor/ghostty && "$ZIG_CMD" build "${TARGET_ARGS[@]}" -Demit-lib-vt=true -Doptimize=ReleaseFast)

echo "Copying dependency libraries..."
SEARCH_DIRS=(
    "vendor/ghostty/.zig-cache"
)
[ -n "${ZIG_LOCAL_CACHE_DIR:-}" ] && SEARCH_DIRS+=("${ZIG_LOCAL_CACHE_DIR}")
[ -n "${ZIG_GLOBAL_CACHE_DIR:-}" ] && SEARCH_DIRS+=("${ZIG_GLOBAL_CACHE_DIR}")

find_static_lib() {
    local base="$1"
    local dir
    local matches=()
    for dir in "${SEARCH_DIRS[@]}"; do
        [ -d "$dir" ] || continue
        while IFS= read -r match; do
            matches+=("$match")
        done < <(find "$dir" \( -name "${base}${STATIC_LIB_EXT}" -o -name "lib${base}.a" \) -print 2>/dev/null)
    done

    if [ "${#matches[@]}" -eq 0 ]; then
        return 1
    fi

    ls -1t -- "${matches[@]}" | head -n 1
}

copy_static_lib() {
    local source="$1"
    local dest_base="$2"
    local dest="vendor/ghostty/zig-out/lib/${dest_base}${STATIC_LIB_EXT}"
    cp "$source" "$dest"
    echo "  ${dest_base}${STATIC_LIB_EXT} <- $source"
}

SIMDUTF="$(find_static_lib simdutf || true)"
HIGHWAY="$(find_static_lib highway || true)"

if [ -z "$SIMDUTF" ]; then
    echo "Error: could not find simdutf static library"
    exit 1
fi
if [ -z "$HIGHWAY" ]; then
    echo "Error: could not find highway static library"
    exit 1
fi

copy_static_lib "$SIMDUTF" "simdutf"
copy_static_lib "$HIGHWAY" "highway"

echo "Building ghostel module..."
"$ZIG_CMD" build "${TARGET_ARGS[@]}" -Doptimize=ReleaseFast

echo "Done! ghostel-module${MODULE_EXT} is ready."
echo "Load in Emacs with: (require 'ghostel)"
