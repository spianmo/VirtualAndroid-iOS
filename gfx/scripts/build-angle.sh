#!/bin/bash
# Build ANGLE (WebKit's ANGLE subset, Metal backend) as libEGL.dylib + libGLESv2.dylib.
# Same recipe as UTM's build_angle. usage: build-angle.sh <macos|ios-sim|ios>
set -euo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-macos}"
SRC="$GFX/src/webkit/Source/ThirdParty/ANGLE"
OUT="$GFX/build-$PLATFORM"
case "$PLATFORM" in
  macos)   SDK=macosx ;;
  ios-sim) SDK=iphonesimulator ;;
  ios)     SDK=iphoneos ;;
esac
mkdir -p "$OUT/angle"
cd "$SRC"
env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")" HOME="$HOME" \
  xcodebuild archive -archivePath "$OUT/angle/ANGLE" \
    -scheme ANGLE -sdk "$SDK" -arch arm64 -configuration Release \
    -derivedDataPath "$OUT/angle/dd" \
    WEBCORE_LIBRARY_DIR=/usr/local/lib NORMAL_UMBRELLA_FRAMEWORKS_DIR="" \
    CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    IPHONEOS_DEPLOYMENT_TARGET=15.0 MACOSX_DEPLOYMENT_TARGET=13.0
mkdir -p "$OUT/prefix/lib" "$OUT/prefix/include"
rsync -a "$OUT/angle/ANGLE.xcarchive/Products/usr/local/lib/" "$OUT/prefix/lib/"
rsync -a "$SRC/include/" "$OUT/prefix/include/angle/"
rm -rf "$OUT/angle/dd"   # intermediates are large
ls -la "$OUT/prefix/lib/" | grep -i -e egl -e gles
