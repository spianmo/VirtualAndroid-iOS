#!/bin/bash
# Package libva_gfx + ANGLE for embedding.
#   macos:       build-macos/dist/{libva_gfx.dylib,libGLESv2.dylib}
#   ios, ios-sim: build-<p>/dist/{va_gfx.framework,GLESv2.framework}
#   xcframework: build-ios-xcframeworks/{va_gfx,GLESv2}.xcframework (needs ios + ios-sim)
set -euo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-macos}"

plist() { # name bundle-id platform
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$1</string>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$3</string></array>
  <key>MinimumOSVersion</key><string>15.0</string>
</dict></plist>
PL
}

if [ "$PLATFORM" = "xcframework" ]; then
  OUT="$GFX/build-ios-xcframeworks"; rm -rf "$OUT"; mkdir -p "$OUT"
  FWS="va_gfx GLESv2"
  [ -d "$GFX/build-ios/dist/MoltenVK.framework" ] && [ -d "$GFX/build-ios-sim/dist/MoltenVK.framework" ] && FWS="$FWS MoltenVK"
  for fw in $FWS; do
    xcodebuild -create-xcframework \
      -framework "$GFX/build-ios/dist/$fw.framework" \
      -framework "$GFX/build-ios-sim/dist/$fw.framework" \
      -output "$OUT/$fw.xcframework"
  done
  ls "$OUT"; exit 0
fi

B="$GFX/build-$PLATFORM"
DIST="$B/dist"
rm -rf "$DIST"; mkdir -p "$DIST"
if [ "$PLATFORM" = "macos" ]; then
  cp "$B/libva_gfx/libva_gfx.dylib" "$DIST/"
  cp "$B/prefix/lib/libGLESv2.dylib" "$DIST/"
  install_name_tool -id @rpath/libGLESv2.dylib "$DIST/libGLESv2.dylib" 2>/dev/null
  [ -f "$B/prefix/lib/libMoltenVK.dylib" ] && cp "$B/prefix/lib/libMoltenVK.dylib" "$DIST/"
  codesign -f -s - "$DIST"/*.dylib
else
  case "$PLATFORM" in ios) PL=iPhoneOS ;; ios-sim) PL=iPhoneSimulator ;; esac
  mkdir -p "$DIST/va_gfx.framework/Headers" "$DIST/GLESv2.framework/Headers"
  cp "$B/libva_gfx/libva_gfx.dylib" "$DIST/va_gfx.framework/va_gfx"
  cp "$GFX/include/va_gfx.h" "$DIST/va_gfx.framework/Headers/"
  plist va_gfx org.virtualandroid.va-gfx "$PL" > "$DIST/va_gfx.framework/Info.plist"
  cp "$B/prefix/lib/libGLESv2.dylib" "$DIST/GLESv2.framework/GLESv2"
  install_name_tool -id @rpath/GLESv2.framework/GLESv2 "$DIST/GLESv2.framework/GLESv2" 2>/dev/null
  rsync -a "$B/prefix/include/angle/GLES2" "$B/prefix/include/angle/GLES3" \
        "$B/prefix/include/angle/EGL" "$B/prefix/include/angle/KHR" "$DIST/GLESv2.framework/Headers/"
  plist GLESv2 org.virtualandroid.angle-glesv2 "$PL" > "$DIST/GLESv2.framework/Info.plist"
  if [ -d "$B/prefix/MoltenVK.framework" ]; then
    cp -a "$B/prefix/MoltenVK.framework" "$DIST/"
    codesign -f -s - "$DIST/MoltenVK.framework"
  fi
  codesign -f -s - "$DIST/va_gfx.framework" "$DIST/GLESv2.framework"
fi
find "$DIST" -maxdepth 2 | sort
