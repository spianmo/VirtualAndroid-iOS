#!/bin/bash
# Build gfxstream host renderer (static) against aemu from build-<platform>/prefix.
# usage: build-gfxstream.sh <platform: macos|ios-sim|ios> [extra meson args]
set -euo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-macos}"; shift || true
SRC="$GFX/src/gfxstream"
OUT="$GFX/build-$PLATFORM"
PREFIX="$OUT/prefix"
CROSS=()
if [ "$PLATFORM" = "macos" ]; then
  export MACOSX_DEPLOYMENT_TARGET=13.0
else
  CROSS+=(--cross-file "$OUT/meson-cross.ini")
fi
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
if [ ! -d "$OUT/gfxstream" ]; then
  meson setup "$OUT/gfxstream" "$SRC" ${CROSS[@]+"${CROSS[@]}"} \
    --prefix="$PREFIX" --buildtype=release -Db_ndebug=true \
    -Ddefault_library=static \
    -Dgfxstream-build=host -Ddecoders=gles,vulkan,composer \
    -Dlog-level=warn "$@"
fi
meson compile -C "$OUT/gfxstream"
meson install -C "$OUT/gfxstream"
