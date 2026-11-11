#!/bin/zsh
# Prebake an Android userdata on macOS: the first boot (vold keys, odrefresh + odsign,
# PackageManager's first scan and first-boot dexopt, settings, launcher) runs once here
# under HVF, then every package is compiled with the "speed" filter, so the iPhone (TCTI)
# never runs the first-boot storm and the JIT has nothing left to compile in them (it stays
# on for apps installed later). Result: an image pack whose
# userdata/encryptionkey/cache qcow2s belong together.
#
#   tools/prebake_userdata.sh [-o PACK_DIR] [--name RUN] [--adb-port PORT] [--disable PKG,...]
#                             [--tcg] [--timeout SECS] [--settle-max SECS] [--keep-disks]
#
#   -o PACK_DIR     output image pack (default app/build/ImagePackPrebaked; manifest.json
#                   "userdata": "prebaked-speed", system/vendor/kernel/ramdisk are APFS clones
#                   of images/android-33/arm64-v8a, see app/scripts/make_userdata_qcow2.sh)
#   --name RUN      run name (engine/run/RUN, default prebake), --adb-port (default 5631)
#   --disable LIST  pm disable-user these packages before the shutdown (default: none)
#   --tcg           prebake under TCG (-cpu cortex-a76) instead of HVF (-cpu host)
#   --timeout SECS  give up (and stop the VM) after this long (default 2400)
#   --settle-max    longest wait for the guest to go idle, per phase (default 900)
#   --keep-disks    keep the raw run disks after the conversion (default: deleted)
#
# Steps: fresh boot (tools/run-macos.sh --fresh --machine ranchu, VA_PREBAKED=1: the guest
# must already boot with the dalvik.vm.* properties the device will use, odrefresh records
# them in cache-info.xml and recompiles when they change) -> sys.boot_completed -> idle
# (odsign verification done, no dex2oat, low load) -> pm compile -m speed -f -a (+
# --secondary-dex) -> idle -> checks: dumpsys package dexopt (every package with code at
# "speed"), dalvik.vm.isa.arm64.* = generic/default (oat files must not use host-only CPU
# features: HVF runs -cpu host, the device QEMU cortex-a76), oatdump headers -> adb shell
# reboot -p and wait for QEMU to exit (clean ext4/dm-default-key shutdown) -> qcow2 pack.
# Log of the checks: $RUN/prebake-report.txt (also copied into the pack as prebake.txt).
#
# Boot from the pack: tools/run-macos.sh --machine ranchu --userdata-from PACK_DIR ...,
# engine/scripts/ios/run_sim.sh --userdata-from PACK_DIR ..., or install it in the app.
set -euo pipefail
zmodload zsh/datetime
ROOT=${0:A:h:h}
OUT=$ROOT/app/build/ImagePackPrebaked
NAME=prebake ADB_PORT=5631 DISABLE= TCG=() TIMEOUT=2400 SETTLE_MAX=900 KEEP_DISKS=0
while (( $# )); do
  case $1 in
    -o) OUT=${2:A}; shift ;;
    --name) NAME=$2; shift ;;
    --adb-port) ADB_PORT=$2; shift ;;
    --disable) DISABLE=$2; shift ;;
    --tcg) TCG=(--tcg) ;;
    --timeout) TIMEOUT=$2; shift ;;
    --settle-max) SETTLE_MAX=$2; shift ;;
    --keep-disks) KEEP_DISKS=1 ;;
    -h|--help) sed -n '2,33p' $0; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
RUN=$ROOT/engine/run/$NAME
SERIAL=127.0.0.1:$ADB_PORT
ADB=(adb -s $SERIAL)
REPORT=$RUN/prebake-report.txt
T0=$EPOCHREALTIME
QPID=

say() { printf '[%6.1fs] %s\n' $(( EPOCHREALTIME - T0 )) "$*" | tee -a $REPORT; }
die() { say "ERROR: $*"; exit 1; }
sh_() { $ADB shell "$@" 2>/dev/null | tr -d '\r' || true; }   # guest exit status ignored
free_mb() { df -m $ROOT | awk 'NR==2 {print $4}'; }
alive() { [[ -n $QPID ]] && kill -0 $QPID 2>/dev/null; }
stop_vm() {  # monitor quit, then kill: never leave the VM running
  alive || return 0
  print quit | nc -U -w 2 $RUN/monitor.sock >/dev/null 2>&1 || true
  for i in {1..20}; do alive || return 0; sleep 0.5; done
  kill $QPID 2>/dev/null || true
}
trap 'stop_vm' EXIT
trap 'exit 130' INT TERM

if [[ -f $RUN/userdata.img ]] && lsof $RUN/userdata.img >/dev/null 2>&1; then
  echo "$RUN/userdata.img is in use: another VM runs on this run dir" >&2; exit 1
fi
(( $(free_mb) > 3000 )) || { echo "only $(free_mb) MB free, need ~3 GB (raw disks + qcow2s)" >&2; exit 1; }
mkdir -p $RUN
: > $REPORT

# 1. Fresh boot with the prebaked profile.
say "fresh boot: run $RUN, adb $SERIAL ${TCG:+(TCG)}"
VA_PREBAKED=1 nohup $ROOT/tools/run-macos.sh --fresh --machine ranchu --name $NAME \
  --adb-port $ADB_PORT $TCG > $RUN/run.out 2>&1 &
QPID=$!   # run-macos.sh execs QEMU, so this is QEMU's pid
deadline=$(( EPOCHREALTIME + TIMEOUT ))
check_time() { alive || die "QEMU exited (see $RUN/run.out)"; (( EPOCHREALTIME < deadline )) || die "timeout"; }

while [[ $(sh_ getprop sys.boot_completed) != 1 ]]; do
  check_time
  adb connect $SERIAL >/dev/null 2>&1 || true
  sleep 2
done
say "sys.boot_completed=1"

# Idle: odsign done, no dex2oat for 30 s, 1-minute load below 1.5 (or SETTLE_MAX).
settle() {  # phase
  local t=$EPOCHREALTIME ok=0 load dex
  while (( ok < 6 )); do
    check_time
    if (( EPOCHREALTIME - t > SETTLE_MAX )); then
      say "warning: $1: not idle after ${SETTLE_MAX}s (load $load, dex2oat '$dex'), going on"
      return 0
    fi
    sleep 5
    dex=$(sh_ pidof dex2oat64 dex2oat)
    load=$(sh_ cat /proc/loadavg | cut -d' ' -f1)
    if [[ -z $dex && $(sh_ getprop odsign.verification.done) == 1 ]] && (( ${load:-9} < 1.5 )); then
      (( ok += 1 ))
    else
      ok=0
    fi
  done
  say "$1: idle after $(printf %.0f $(( EPOCHREALTIME - t )))s (load $load)"
}
settle "first boot"
[[ $(sh_ getprop odsign.verification.success) == 1 ]] || die "odsign verification failed"

# The oat files must run on the device's cortex-a76, not just on this Mac (-cpu host).
variant=$(sh_ getprop dalvik.vm.isa.arm64.variant)
features=$(sh_ getprop dalvik.vm.isa.arm64.features)
say "dalvik.vm.isa.arm64.variant=$variant features=$features usejit=$(sh_ getprop dalvik.vm.usejit)"
[[ $variant == generic && $features == default ]] ||
  die "dex2oat would target this host's CPU: pin dalvik.vm.isa.arm64.* in the prebaked profile or use --tcg"

# 2. Compile everything with "speed".
t=$EPOCHREALTIME
sh_ pm compile -m speed -f -a > $RUN/compile.out || true
say "pm compile -m speed -f -a: $(printf %.0f $(( EPOCHREALTIME - t )))s, $(grep -c '^[0-9]*/' $RUN/compile.out) packages"
grep -h '^Failure' $RUN/compile.out | tee -a $REPORT || true
sh_ pm compile -m speed -f --secondary-dex -a > $RUN/compile-secondary.out || true
say "secondary dex: $(grep -h '^Failure' $RUN/compile-secondary.out || echo ok)"
settle "after compile"

# 3. Checks.
sh_ dumpsys package dexopt > $RUN/dexopt.txt
# Per package: the arm64 status lines ("arm64: [status=speed] [reason=cmdline]").
awk '/^  \[/ { pkg = substr($1, 2, length($1) - 2) }
     /arm64: \[status=/ { match($0, /status=[^]]*/); s = substr($0, RSTART + 7, RLENGTH - 7); print pkg, s }' \
  $RUN/dexopt.txt > $RUN/dexopt-status.txt
total=$(wc -l < $RUN/dexopt-status.txt | tr -d ' ')
speed=$(grep -c ' speed$' $RUN/dexopt-status.txt || true)
nocode=$(grep -c ' run-from-apk$' $RUN/dexopt-status.txt || true)
say "dexopt: $total dex files, $speed speed, $nocode run-from-apk (no code: RROs)"
others=$(grep -v -e ' speed$' -e ' run-from-apk$' $RUN/dexopt-status.txt || true)
[[ -n $others ]] && say "not speed: ${(f)others}"
for p in com.android.systemui com.android.launcher3 com.android.settings; do
  say "  $p: $(awk -v p=$p '$1 == p {print $2}' $RUN/dexopt-status.txt | paste -sd, -)"
done
oat=$(sh_ su 0 ls /data/dalvik-cache/arm64 | grep -m1 'SystemUI.apk@classes.dex' || true)
for f in /system/framework/arm64/boot-framework.oat /system/framework/oat/arm64/services.odex \
         ${oat:+/data/dalvik-cache/arm64/$oat}; do
  hdr=$(sh_ su 0 /apex/com.android.art/bin/oatdump --header-only --oat-file=$f)
  say "  $f: features $(print -r -- $hdr | awk '/INSTRUCTION SET FEATURES/ {getline; print}')," \
      "$(print -r -- $hdr | grep -m1 'compiler-filter')"
done
say "focus: $(sh_ dumpsys window | grep -m1 mCurrentFocus | sed 's/^ *//')"
say "guest /data: $(sh_ df -h /data | awk 'NR==2 {print $3 " used"}')"
for p in ${(s:,:)DISABLE}; do
  say "disable $p: $(sh_ pm disable-user --user 0 $p)"
done

# 4. Clean poweroff: init unmounts /data and /metadata, the guest powers QEMU off.
say "poweroff"
sh_ reboot -p >/dev/null || true
for i in {1..180}; do alive || break; sleep 1; done
alive && die "QEMU still running 180 s after reboot -p"
grep -aq 'Umounted .*:/data opts' $RUN/serial.log || die "/data was not unmounted (serial.log)"
grep -aq 'reboot: Power down' $RUN/serial.log || die "no clean power down (serial.log)"
say "QEMU exited after a clean shutdown"

# 5. The pack: qcow2s from the run disks + clones of the image.
need=$(( $(du -m $RUN/userdata.img | cut -f1) + 300 ))
(( $(free_mb) > need )) || die "only $(free_mb) MB free, the conversion needs ~$need MB"
$ROOT/app/scripts/make_userdata_qcow2.sh -o $OUT --from-run $RUN --userdata-kind prebaked-speed | tee -a $REPORT
(( KEEP_DISKS )) || rm -f $RUN/userdata.img $RUN/encryptionkey.img $RUN/cache.img
cp $REPORT $OUT/prebake.txt
say "done: $OUT"
