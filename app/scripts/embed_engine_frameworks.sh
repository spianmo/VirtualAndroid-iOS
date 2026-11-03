#!/bin/bash
# Xcode build phase: embeds the engine frameworks into the app bundle when
# they have been built, so the real engine becomes available at runtime
# (QemuEngine.isAvailable). Without them the app runs the stub engine.
#
#   VA_ENGINE_XCFRAMEWORKS  directory with *.xcframework
#                           (default: <repo>/engine/build-ios/xcframeworks)
#   VA_STUB_ONLY=1          skip embedding entirely
#
# Every xcframework in the directory is embedded (QEMU, libva_gfx and their
# dependencies such as glib/pixman), using the slice for $PLATFORM_NAME.
set -euo pipefail

SRC="${VA_ENGINE_XCFRAMEWORKS:-${SRCROOT}/../engine/build-ios/xcframeworks}"
DEST="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

if [[ "${VA_STUB_ONLY:-0}" == 1 ]]; then
  echo "note: VA_STUB_ONLY=1, not embedding engine frameworks"
  exit 0
fi
if [[ ! -d "$SRC" ]]; then
  echo "note: no engine frameworks at $SRC; the app will use the stub engine"
  exit 0
fi

case "${PLATFORM_NAME}" in
  iphonesimulator) want='simulator' ;;
  iphoneos) want='device' ;;
  *) echo "note: platform ${PLATFORM_NAME} not handled"; exit 0 ;;
esac

mkdir -p "$DEST"
shopt -s nullglob
count=0
for xc in "$SRC"/*.xcframework; do
  slice=""
  for s in "$xc"/ios-*; do
    [[ -d "$s" ]] || continue
    base=$(basename "$s")
    case "$base" in
      *arm64*simulator*) [[ $want == simulator ]] && slice="$s" ;;
      *simulator*|*maccatalyst*) ;;
      *arm64*) [[ $want == device ]] && slice="$s" ;;
    esac
  done
  if [[ -z "$slice" ]]; then
    echo "warning: $(basename "$xc") has no arm64 ${want} slice, skipped"
    continue
  fi
  [[ $(basename "$xc") == qemu-aarch64-softmmu.xcframework ]] && qemu_slice=$(basename "$slice")
  for item in "$slice"/*.framework "$slice"/*.dylib; do
    name=$(basename "$item")
    rm -rf "${DEST:?}/$name"
    cp -R "$item" "$DEST/"
    # Headers/modules are not needed at runtime.
    rm -rf "$DEST/$name/Headers" "$DEST/$name/Modules" 2>/dev/null || true
    if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
      codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "$DEST/$name"
    fi
    count=$((count + 1))
  done
done
# Record which TCG backend the embedded QEMU slice was built with (tcg = JIT,
# tcti = threaded interpreter) so the app picks matching -accel options.
BACKEND_FILE="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/VAEngineBackend.txt"
rm -f "$BACKEND_FILE"
if [[ -f "$SRC/qemu-backends.txt" && -n "${qemu_slice:-}" ]]; then
  backend=$(awk -F: -v s="$qemu_slice" '{gsub(/ /,"",$1); gsub(/ /,"",$2); if ($1==s) print $2}' "$SRC/qemu-backends.txt")
  [[ -n "$backend" ]] && echo "$backend" > "$BACKEND_FILE" && echo "QEMU slice $qemu_slice backend: $backend"
fi
echo "embedded $count engine framework(s) from $SRC into $DEST"
