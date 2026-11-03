#!/bin/bash
# Build libva_gfx (glue + gfxstream + aemu, statically linked; exports va_gfx_* only).
# usage: build.sh <macos|ios-sim|ios>
set -euo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$GFX/.." && pwd)"
PLATFORM="${1:-macos}"
OUT="$GFX/build-$PLATFORM"
PREFIX="$OUT/prefix"
GS="$GFX/src/gfxstream"
OBJ="$OUT/libva_gfx"
mkdir -p "$OBJ"

case "$PLATFORM" in
  macos)   SDK=macosx;          TARGET=arm64-apple-macos13.0 ;;
  ios-sim) SDK=iphonesimulator; TARGET=arm64-apple-ios15.0-simulator ;;
  ios)     SDK=iphoneos;        TARGET=arm64-apple-ios15.0 ;;
esac
SYSROOT="$(xcrun --sdk $SDK --show-sdk-path)"
CC="$(xcrun --sdk $SDK -f clang)"
CXX="$(xcrun --sdk $SDK -f clang++)"
COMMON=(-target "$TARGET" -isysroot "$SYSROOT" -O2 -g -fPIC -fvisibility=hidden)

INC=(
  -I"$GFX/include" -I"$GFX/libva_gfx"
  -I"$GS/host/gl/gl-host-common/include"
  -I"$GS/include" -I"$GS/host" -I"$GS/host/include"
  -I"$GS/host/features/include" -I"$GS/host/tracing/include"
  -I"$GS/host/backend/include" -I"$GS/utils/include" -I"$GS/common/utils/include"
  -I"$GS/common/opengl/include"
  -I"$PREFIX/include/aemu/host-common" -I"$PREFIX/include" -I"$PREFIX/include/aemu/snapshot"
)
DEFS=(-DGFXSTREAM_ENABLE_HOST_GLES=1 -DGFXSTREAM_MESON_BUILD=1 -DGFXSTREAM_ENABLE_HOST_MAGMA=0)
[ "$PLATFORM" != "macos" ] && DEFS+=(-DVA_GFX_IOS=1)

"$CC" "${COMMON[@]}" -std=c11 -I"$GFX/include" -I"$GFX/libva_gfx" -I"$ROOT/engine/qemu/include" \
  -c "$GFX/libva_gfx/va_gfx_pipe_shim.c" -o "$OBJ/va_gfx_pipe_shim.o"
for f in va_gfx va_gfx_present; do
  "$CXX" "${COMMON[@]}" -std=gnu++17 "${INC[@]}" "${DEFS[@]}" -Wno-extern-c-compat \
    -c "$GFX/libva_gfx/$f.cpp" -o "$OBJ/$f.o"
done
# aemu's gfxstream build-config leaves VmLock.cpp out of aemu-host-common.
"$CXX" "${COMMON[@]}" -std=gnu++17 "${INC[@]}" -I"$GFX/src/aemu/host-common/include/host-common" \
  -c "$GFX/src/aemu/host-common/VmLock.cpp" -o "$OBJ/aemu_VmLock.o"

LIBS=()
while IFS= read -r a; do LIBS+=("$a"); done < <(find "$OUT/gfxstream" -name '*.a' | sort)
LIBS+=("$PREFIX/lib/libaemu-host-common.a" "$PREFIX/lib/libaemu-base.a"
       "$PREFIX/lib/libaemu-snapshot.a" "$PREFIX/lib/libaemu-logging.a")

FW=(-framework Foundation -framework IOSurface -framework CoreFoundation -framework QuartzCore
    -framework Metal -framework CoreGraphics -framework IOKit)
if [ "$PLATFORM" = "macos" ]; then
  FW+=(-framework AppKit -framework OpenGL)
  INSTALL_NAME="@rpath/libva_gfx.dylib"
else
  FW+=(-framework UIKit)
  INSTALL_NAME="@rpath/va_gfx.framework/va_gfx"
fi

"$CXX" "${COMMON[@]}" -dynamiclib -o "$OBJ/libva_gfx.dylib" \
  -install_name "$INSTALL_NAME" \
  -Wl,-exported_symbols_list,"$GFX/libva_gfx/exports.txt" -Wl,-dead_strip \
  "$OBJ/va_gfx_pipe_shim.o" "$OBJ/va_gfx.o" "$OBJ/va_gfx_present.o" "$OBJ/aemu_VmLock.o" \
  "${LIBS[@]}" "${FW[@]}" -lc++
echo "built $OBJ/libva_gfx.dylib"
nm -gU "$OBJ/libva_gfx.dylib" | grep va_gfx
