#!/bin/bash
# Combine the per-platform frameworks into xcframeworks for the app.
#
#   engine/scripts/ios/make_xcframeworks.sh [--sim-backend tcg|tcti] [--device-backend tcti|tcg]
#
# Inputs:  engine/build-ios/{ios,ios_simulator}-arm64/Frameworks/*.framework  (deps)
#          engine/build-ios/<platform>-arm64/qemu-<backend>/Frameworks/qemu-aarch64-softmmu.framework
#          engine/build-ios/<platform>-arm64/qemu-tcti/Frameworks/va_aot.framework (build_aot.sh)
# Output:  engine/build-ios/xcframeworks/<name>.xcframework
#          (a platform that has not been built is simply left out; va_aot only
#          for TCTI slices it is bound to)
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

# Only the frameworks QEMU actually loads (transitive @rpath imports), so
# that unused glib/iconv bits (gthread, girepository, charset) stay out.
fw_path () {  # $1 platform dir, $2 backend, $3 name
    if [ "$3" = qemu-aarch64-softmmu ]; then echo "$1/qemu-$2/Frameworks/$3.framework/$3"
    else echo "$1/Frameworks/$3.framework/$3"; fi
}
closure () {  # $1 platform dir, $2 backend
    todo="qemu-aarch64-softmmu"; seen=" "
    while [ -n "$todo" ]; do
        set -- $todo; n=$1; shift; todo="$*"
        case "$seen" in *" $n "*) continue ;; esac
        seen="$seen$n "
        f="$(fw_path "$PLAT" "$BK" "$n")"
        [ -f "$f" ] || continue
        todo="$todo $(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep '^@rpath/' \
                     | sed 's|^@rpath/\([^/]*\)\.framework/.*|\1|' | tr '\n' ' ')"
    done
    echo $seen
}
names="$( (PLAT="$SIM" BK="$SIM_BACKEND" closure; PLAT="$DEV" BK="$DEV_BACKEND" closure) | tr ' ' '\n' | sort -u)"
[ -n "$names" ] || { echo "nothing built yet" >&2; exit 1; }

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

# AOT cache (build_aot.sh): only next to a TCTI QEMU slice, and only when it
# is bound to that exact QEMU binary (else QEMU would reject it at load).
aot_fw () {  # $1 platform dir, $2 backend
    [ "$2" = tcti ] || return 0
    q="$1/qemu-tcti"
    fw="$q/Frameworks/va_aot.framework"
    [ -d "$fw" ] || return 0
    if [ "$(shasum "$q/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu" | awk '{print $1}')" \
         != "$(cat "$q/aot/bound-qemu.sha1" 2>/dev/null)" ]; then
        echo "warning: $fw is bound to an older QEMU build, left out (run build_aot.sh again)" >&2
        return 0
    fi
    echo "$fw"
}
args=()
d="$(aot_fw "$DEV" "$DEV_BACKEND")"
s="$(aot_fw "$SIM" "$SIM_BACKEND")"
[ -n "$d" ] && args+=(-framework "$d")
[ -n "$s" ] && args+=(-framework "$s")
rm -rf "$XCF/va_aot.xcframework"
if [ ${#args[@]} -gt 0 ]; then
    xcodebuild -create-xcframework "${args[@]}" -output "$XCF/va_aot.xcframework" >/dev/null
    echo "va_aot.xcframework: $(ls "$XCF/va_aot.xcframework" | grep -v Info.plist | tr '\n' ' ')"
fi
