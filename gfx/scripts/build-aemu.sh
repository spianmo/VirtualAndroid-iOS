#!/bin/bash
# Build aemu (hardware/google/aemu) static libs + pkg-config files.
# usage: build-aemu.sh <platform: macos|ios-sim|ios> 
set -euo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-macos}"
SRC="$GFX/src/aemu"
OUT="$GFX/build-$PLATFORM"
PREFIX="$OUT/prefix"
EXTRA=()
case "$PLATFORM" in
  macos)   EXTRA+=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0) ;;
  ios-sim) EXTRA+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0) ;;
  ios)     EXTRA+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0) ;;
esac
cmake -S "$SRC" -B "$OUT/aemu" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DAEMU_COMMON_GEN_PKGCONFIG=ON \
  -DAEMU_COMMON_BUILD_CONFIG=gfxstream \
  -DENABLE_VKCEREAL_TESTS=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  "${EXTRA[@]}"
cmake --build "$OUT/aemu" -j 8
cmake --install "$OUT/aemu"
