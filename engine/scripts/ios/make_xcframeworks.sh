#!/bin/bash
# Combine the per-platform frameworks into xcframeworks for the app.
#
#   engine/scripts/ios/make_xcframeworks.sh [--sim-backend tcg|tcti|tcg+tcti]
#                                           [--device-backend tcti|tcg|tcg+tcti]
#
# A backend "tcg+tcti" embeds two engines for that platform: the JIT build as
# qemu-aarch64-softmmu (used when the process can JIT, e.g. launched from
# StikDebug) and the TCTI build renamed to qemu-aarch64-softmmu-tcti (the
# fallback, with its AOT cache). The app picks one at launch
# (QemuEngine.selectFramework).
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
# "tcg+tcti": primary JIT slice plus a secondary TCTI engine
case "$SIM_BACKEND" in tcg+tcti) SIM_BACKEND=tcg; SIM_TCTI2=y ;; tcg|tcti) ;; *) echo "bad --sim-backend" >&2; exit 2 ;; esac
case "$DEV_BACKEND" in tcg+tcti) DEV_BACKEND=tcg; DEV_TCTI2=y ;; tcg|tcti) ;; *) echo "bad --device-backend" >&2; exit 2 ;; esac
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

# Secondary TCTI engine next to a JIT slice: the TCTI framework renamed to
# qemu-aarch64-softmmu-tcti (install name, executable, bundle id), so both can
# live in the app's Frameworks/. Only load commands and Info.plist change; the
# code (and so the AOT cache binding, checked against helper offsets) does not.
STAGE="$OUT/tcti-secondary"
tcti2_fw () {  # $1 platform dir -> path of the renamed framework
    src="$1/qemu-tcti/Frameworks/qemu-aarch64-softmmu.framework"
    [ -f "$src/qemu-aarch64-softmmu" ] || { echo "warning: no TCTI build in $1" >&2; return 0; }
    # The app treats the two engines as interchangeable for snapshots (same
    # devices, same migration format): both must come from the same tree, and
    # the TCTI build must not be older than the newest engine source change.
    if [ "$(cat "$1/qemu-tcti/source" 2>/dev/null)" != "$(cat "$1/qemu-tcg/source" 2>/dev/null)" ]; then
        echo "warning: TCTI and JIT builds in $1 come from different source trees" >&2
    fi
    newer=$(find "$(cat "$1/qemu-tcti/source")" \( -name '*.c' -o -name '*.h' -o -name '*.inc' \) \
                 -path '*/hw/*' -newer "$src/qemu-aarch64-softmmu" -print -quit 2>/dev/null)
    if [ -n "$newer" ]; then
        echo "warning: TCTI build in $1 is older than $newer (device code changed since):" >&2
        echo "         rebuild it (build_qemu.sh -b tcti) or a JIT snapshot may not restore under TCTI" >&2
    fi
    dst="$STAGE/$(basename "$1")/qemu-aarch64-softmmu-tcti.framework"
    rm -rf "$dst"; mkdir -p "$(dirname "$dst")"
    cp -R "$src" "$dst"
    rm -rf "$dst/_CodeSignature"
    mv "$dst/qemu-aarch64-softmmu" "$dst/qemu-aarch64-softmmu-tcti"
    install_name_tool -id @rpath/qemu-aarch64-softmmu-tcti.framework/qemu-aarch64-softmmu-tcti \
        "$dst/qemu-aarch64-softmmu-tcti" 2>/dev/null
    plutil -replace CFBundleExecutable -string qemu-aarch64-softmmu-tcti "$dst/Info.plist"
    plutil -replace CFBundleName -string qemu-aarch64-softmmu-tcti "$dst/Info.plist"
    plutil -replace CFBundleIdentifier -string dev.virtualandroid.qemu-aarch64-softmmu-tcti "$dst/Info.plist"
    codesign --force --sign - --timestamp=none "$dst" >/dev/null 2>&1
    echo "$dst"
}
rm -rf "$XCF/qemu-aarch64-softmmu-tcti.xcframework"
args=()
if [ -n "$DEV_TCTI2" ]; then d="$(tcti2_fw "$DEV")"; [ -n "$d" ] && args+=(-framework "$d"); fi
if [ -n "$SIM_TCTI2" ]; then s="$(tcti2_fw "$SIM")"; [ -n "$s" ] && args+=(-framework "$s"); fi
if [ ${#args[@]} -gt 0 ]; then
    xcodebuild -create-xcframework "${args[@]}" -output "$XCF/qemu-aarch64-softmmu-tcti.xcframework" >/dev/null
    echo "qemu-aarch64-softmmu-tcti.xcframework: $(ls "$XCF/qemu-aarch64-softmmu-tcti.xcframework" | grep -v Info.plist | tr '\n' ' ')"
fi

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
# the AOT cache belongs to the TCTI engine, primary or secondary
d="$(aot_fw "$DEV" "$([ -n "$DEV_TCTI2" ] && echo tcti || echo "$DEV_BACKEND")")"
s="$(aot_fw "$SIM" "$([ -n "$SIM_TCTI2" ] && echo tcti || echo "$SIM_BACKEND")")"
[ -n "$d" ] && args+=(-framework "$d")
[ -n "$s" ] && args+=(-framework "$s")
rm -rf "$XCF/va_aot.xcframework"
if [ ${#args[@]} -gt 0 ]; then
    xcodebuild -create-xcframework "${args[@]}" -output "$XCF/va_aot.xcframework" >/dev/null
    echo "va_aot.xcframework: $(ls "$XCF/va_aot.xcframework" | grep -v Info.plist | tr '\n' ' ')"
fi
