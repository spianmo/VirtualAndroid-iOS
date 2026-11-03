#!/bin/bash
# Combine the per-platform frameworks into xcframeworks for the app.
#
#   engine/scripts/ios/make_xcframeworks.sh [--sim-backend tcg|tcti] [--device-backend tcti|tcg]
#
# Inputs:  engine/build-ios/{ios,ios_simulator}-arm64/Frameworks/*.framework  (deps)
#          engine/build-ios/<platform>-arm64/qemu-<backend>/Frameworks/qemu-aarch64-softmmu.framework
# Output:  engine/build-ios/xcframeworks/<name>.xcframework
#          (a platform that has not been built is simply left out)
set -e
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/engine/build-ios"
SIM_BACKEND=tcg
DEV_BACKEND=tcti
while [ $# -gt 0 ]; do
    case "$1" in
    --sim-backend ) SIM_BACKEND="$2"; shift ;;
    --device-backend ) DEV_BACKEND="$2"; shift ;;
    * ) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
SIM="$OUT/ios_simulator-arm64"
DEV="$OUT/ios-arm64"
XCF="$OUT/xcframeworks"
mkdir -p "$XCF"

names=$( (ls "$SIM/Frameworks" "$DEV/Frameworks" 2>/dev/null; echo qemu-aarch64-softmmu.framework) \
         | grep '\.framework$' | sort -u | sed 's/\.framework$//')
for n in $names; do
    args=()
    if [ "$n" = qemu-aarch64-softmmu ]; then
        d="$DEV/qemu-$DEV_BACKEND/Frameworks/$n.framework"
        s="$SIM/qemu-$SIM_BACKEND/Frameworks/$n.framework"
    else
        d="$DEV/Frameworks/$n.framework"
        s="$SIM/Frameworks/$n.framework"
    fi
    [ -d "$d" ] && args+=(-framework "$d")
    [ -d "$s" ] && args+=(-framework "$s")
    [ ${#args[@]} -gt 0 ] || continue
    rm -rf "$XCF/$n.xcframework"
    xcodebuild -create-xcframework "${args[@]}" -output "$XCF/$n.xcframework" >/dev/null
    echo "$n.xcframework: $(ls "$XCF/$n.xcframework" | grep -v Info.plist | tr '\n' ' ')"
done
# record which backend each QEMU slice uses
cat > "$XCF/qemu-backends.txt" <<EOF
ios-arm64           : $DEV_BACKEND
ios-arm64-simulator : $SIM_BACKEND
EOF
