#!/bin/bash
# Build ghostel and its vendored dependencies.
#
# This script:
# 1. Builds libghostty-vt from the vendored ghostty submodule
# 2. Copies bundled dependency libraries (simdutf, highway) to stable paths
# 3. Builds the ghostel Emacs dynamic module
set -e

cd "$(dirname "$0")"

# Check submodule
if [ ! -f vendor/ghostty/build.zig ]; then
    echo "Initializing ghostty submodule..."
    git submodule update --init vendor/ghostty
fi

# Build libghostty-vt
echo "Building libghostty-vt..."
(cd vendor/ghostty && zig build -Demit-lib-vt=true)

# Copy bundled C++ dependencies to stable paths.
# These are built by ghostty's zig build into a cache directory with
# hash-based names.  Search the local .zig-cache first, then fall back
# to the global/local cache dirs (which CI tools like setup-zig may override).
echo "Copying dependency libraries..."
SEARCH_DIRS="vendor/ghostty/.zig-cache"
[ -n "$ZIG_LOCAL_CACHE_DIR" ] && SEARCH_DIRS="$SEARCH_DIRS $ZIG_LOCAL_CACHE_DIR"
[ -n "$ZIG_GLOBAL_CACHE_DIR" ] && SEARCH_DIRS="$SEARCH_DIRS $ZIG_GLOBAL_CACHE_DIR"

SIMDUTF=""
HIGHWAY=""
for dir in $SEARCH_DIRS; do
    [ -d "$dir" ] || continue
    [ -z "$SIMDUTF" ] && SIMDUTF=$(find "$dir" -name "libsimdutf.a" -print -quit 2>/dev/null)
    [ -z "$HIGHWAY" ] && HIGHWAY=$(find "$dir" -name "libhighway.a" -print -quit 2>/dev/null)
done

if [ -z "$SIMDUTF" ]; then
    echo "Error: could not find libsimdutf.a in vendor/ghostty/.zig-cache"
    exit 1
fi
if [ -z "$HIGHWAY" ]; then
    echo "Error: could not find libhighway.a in vendor/ghostty/.zig-cache"
    exit 1
fi

cp "$SIMDUTF" vendor/ghostty/zig-out/lib/libsimdutf.a
cp "$HIGHWAY" vendor/ghostty/zig-out/lib/libhighway.a
echo "  libsimdutf.a <- $SIMDUTF"
echo "  libhighway.a <- $HIGHWAY"

# Build ghostel module
echo "Building ghostel module..."
zig build

echo "Done! ghostel-module$(python3 -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX") or ".so")' 2>/dev/null || echo '.dylib') is ready."
echo "Load in Emacs with: (require 'ghostel)"
