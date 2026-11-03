#!/bin/bash
# Build MoltenVK (KhronosGroup, pinned tag) with its own build system, like UTM's
# build_moltenvk. usage: build-moltenvk.sh <ios-sim|ios|macos>
# Output: build-<p>/prefix/MoltenVK.framework (iOS) or prefix/lib/libMoltenVK.dylib (macOS)
set -euo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-ios-sim}"
TAG=v1.4.2
SRC="$GFX/src/MoltenVK"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/KhronosGroup/MoltenVK.git "$SRC"
fi
case "$PLATFORM" in
  ios-sim) MVK=iossim ;;
  ios)     MVK=ios ;;
  macos)   MVK=macos ;;
esac
cd "$SRC"
CLEAN_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$(dirname "$(command -v python3)")"
env -i PATH="$CLEAN_PATH" HOME="$HOME" LANG=en_US.UTF-8 ./fetchDependencies --$MVK
env -i PATH="$CLEAN_PATH" HOME="$HOME" LANG=en_US.UTF-8 make $MVK
OUT="$GFX/build-$PLATFORM/prefix"
mkdir -p "$OUT/lib"
if [ "$PLATFORM" = "macos" ]; then
  cp -a Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib "$OUT/lib/"
else
  find Package/Release/MoltenVK/dynamic/MoltenVK.xcframework -name MoltenVK.framework -path "*$( [ $MVK = iossim ] && echo simulator || echo ios-arm64 )*" \
    -exec cp -a {} "$OUT/" \; || true
  ls -d "$OUT"/MoltenVK.framework
fi
du -sh "$SRC"
