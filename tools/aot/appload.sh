#!/bin/zsh
# Third-party app workload for AOT profiling and capture (docs/AOT.md "Third-party apps"):
# what users do with apps they install in the guest, so that installd/dex2oat, the
# runtime class verifier/linker and app start-up paths of ART get into the cache.
#
#   tools/aot/appload.sh SERIAL APK... [--scale N]
#
# For each APK: adb install (PackageManager + installd dex2oat with the install filter),
# then the app's launcher activity is started cold twice (force-stop in between), with a
# few swipes, and the time to "Displayed" is logged. Ends with "cmd package compile -m
# verify -f" of the first app (dex2oat's verifier on a large app again, outside the
# install). --scale stretches the waits for slow backends (TCTI: 3).
# Output on stdout: one line per step with seconds.
SER=$1; shift
APKS=() SCALE=1
while (( $# )); do
  case $1 in
    --scale) SCALE=$2; shift ;;
    *) APKS+=(${1:A}) ;;
  esac
  shift
done
zmodload zsh/datetime
AAPT2=${AAPT2:-$(ls -d ~/Library/Android/sdk/build-tools/*/aapt2(N) | tail -1)}
log() { print -r -- "[$(date +%H:%M:%S)] $*"; }
sh_() { adb -s $SER shell "$@" 2>/dev/null | tr -d '\r'; }
wait_s() { sleep $(( $1 * SCALE )); }
pkgs=()
for apk in $APKS; do
  t=$EPOCHREALTIME
  out=$(adb -s $SER install -r -g $apk 2>&1 | tail -1)
  pkg=$($AAPT2 dump packagename $apk 2>/dev/null)
  log "install ${apk:t} -> $pkg: $out ($(( EPOCHREALTIME - t ))s)"
  pkgs+=($pkg)
done
for pkg in $pkgs; do
  act=$(sh_ cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $pkg | tail -1)
  [[ $act == */* ]] || { log "$pkg: no launcher activity"; continue; }
  for run in 1 2; do
    sh_ am force-stop $pkg; sleep 3
    t=$EPOCHREALTIME
    r=$(sh_ am start -W -n $act | grep -E "TotalTime|Status" | tr '\n' ' ')
    log "start $pkg run $run: $r ($(( EPOCHREALTIME - t ))s)"
    wait_s 20
    for s in 1 2 3; do sh_ input swipe 540 1800 540 700 300; wait_s 2; done
    sh_ input swipe 540 700 540 1800 300; wait_s 5
    sh_ input keyevent KEYCODE_HOME; wait_s 3
  done
done
if (( ${#pkgs} )); then
  t=$EPOCHREALTIME
  r=$(sh_ cmd package compile -m verify -f ${pkgs[1]} | tail -1)
  log "compile -m verify -f ${pkgs[1]}: $r ($(( EPOCHREALTIME - t ))s)"
fi
log done
