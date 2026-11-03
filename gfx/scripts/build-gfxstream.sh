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
  case "$PLATFORM" in
    ios-sim) SDK=iphonesimulator; TRIPLE=arm64-apple-ios15.0-simulator; SUB=ios-simulator ;;
    ios)     SDK=iphoneos;        TRIPLE=arm64-apple-ios15.0;           SUB=ios ;;
  esac
  SYSROOT="$(xcrun --sdk $SDK --show-sdk-path)"
  CLANG="$(xcrun --sdk $SDK -f clang)"
  CLANGXX="$(xcrun --sdk $SDK -f clang++)"
  ARGS="['-target', '$TRIPLE', '-isysroot', '$SYSROOT']"
  mkdir -p "$OUT"
  cat > "$OUT/meson-cross.ini" <<INI
[binaries]
c = '$CLANG'
cpp = '$CLANGXX'
objc = '$CLANG'
objcpp = '$CLANGXX'
ar = '$(xcrun --sdk $SDK -f ar)'
strip = '$(xcrun --sdk $SDK -f strip)'
pkg-config = '$(command -v pkg-config)'

[built-in options]
c_args = $ARGS
cpp_args = $ARGS
objc_args = $ARGS
objcpp_args = $ARGS
c_link_args = $ARGS
cpp_link_args = $ARGS
objc_link_args = $ARGS
objcpp_link_args = $ARGS

[host_machine]
system = 'darwin'
subsystem = '$SUB'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
INI
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
