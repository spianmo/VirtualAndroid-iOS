#!/bin/zsh
# M4 end-to-end check in the simulator (docs/SNAPSHOT.md):
#   1. launch the app (cold boot unless a clean snapshot exists) and wait until
#      the guest is usable (adb: launcher focused; stub: "boot completed"),
#   2. send it to the background (opens Settings) -> app suspends the VM,
#   3. kill it (simctl terminate), relaunch, and time restore -> interactive.
#
#   app/scripts/m4_e2e.sh [--udid UDID] [--stub] [--rounds N] [--adb-port 5570] [-- extra launch args]
#
# Needs the app installed with the image pack (QEMU) and `log stream` access.
# Prints a summary; app log in .logs/app-m4/e2e-log.txt, screenshots in .logs/app-m4/.
set -euo pipefail
zmodload zsh/datetime
ROOT=${0:A:h:h:h}
OUT=$ROOT/.logs/app-m4
UDID=$(cat $ROOT/.logs/app-sim-udid.txt 2>/dev/null || true)
ENGINE=qemu ROUNDS=1 PORT=5570
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
while (( $# )); do
  case $1 in
    --udid) UDID=$2; shift ;;
    --stub) ENGINE=stub ;;
    --rounds) ROUNDS=$2; shift ;;
    --adb-port) PORT=$2; shift ;;
    --) shift; break ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
APP=dev.virtualandroid.app
ARGS=(-VAEngine $ENGINE -VANavExpanded NO -VAForceOrientation portrait -VAAdbPort $PORT "$@")
mkdir -p $OUT
LOG=$OUT/e2e-log.txt
: > $LOG
xcrun simctl spawn $UDID log stream --level info --predicate "subsystem == \"$APP\"" >> $LOG 2>&1 &
LOGPID=$!
trap 'kill $LOGPID 2>/dev/null' EXIT
sleep 1

since() { printf '%.1f' $(( EPOCHREALTIME - $1 )); }
wait_log() {  # pattern timeout -> 0 when seen after the current mark
  local pat=$1 t=$2 start=$EPOCHREALTIME
  while (( EPOCHREALTIME - start < t )); do
    tail -n +$MARK $LOG | grep -qE "$pat" && return 0
    sleep 0.1
  done
  return 1
}
mark() { MARK=$(( $(wc -l < $LOG) + 1 )); }
adb_focus() {
  $ADB connect 127.0.0.1:$PORT >/dev/null 2>&1 || true
  perl -e 'alarm 4; exec @ARGV' $ADB -s 127.0.0.1:$PORT shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true
}
wait_interactive() {  # timeout
  local t=$1 start=$EPOCHREALTIME
  if [[ $ENGINE == stub ]]; then wait_log "boot completed|first live frame" $t; return; fi
  while (( EPOCHREALTIME - start < t )); do
    [[ "$(adb_focus)" == *launcher* ]] && return 0
    sleep 0.5
  done
  return 1
}

echo "device $UDID, engine $ENGINE"
mark; T0=$EPOCHREALTIME
xcrun simctl launch --terminate-running-process $UDID $APP $ARGS >/dev/null
wait_log "cold boot|restoring" 30 || true
echo "launch: $(tail -n +$MARK $LOG | grep -oE '(cold boot: .*|snapshot valid.*)' | head -1)"
wait_interactive 900 || { echo "guest not interactive"; exit 1; }
echo "interactive after $(since $T0) s"
sleep 5

for r in $(seq 1 $ROUNDS); do
  echo "== round $r"
  mark; T1=$EPOCHREALTIME
  xcrun simctl launch $UDID com.apple.Preferences >/dev/null
  if wait_log "snapshot saved|suspend failed" 30; then
    echo "background -> $(tail -n +$MARK $LOG | grep -oE '(snapshot saved.*|suspend failed.*)' | head -1) [$(since $T1) s wall]"
  else
    echo "no suspend within 30 s"; exit 1
  fi
  xcrun simctl terminate $UDID $APP
  sleep 1
  mark; T2=$EPOCHREALTIME
  xcrun simctl launch $UDID $APP $ARGS >/dev/null
  wait_log "last frame shown" 10 && xcrun simctl io $UDID screenshot $OUT/round$r-restoring.png >/dev/null 2>&1 || true
  if ! wait_log "guest running|restore failed|cold boot" 120; then echo "no restore"; exit 1; fi
  tail -n +$MARK $LOG | grep -oE '(cold boot: .*|restore failed.*)' | head -1 || true
  wait_log "first live frame" 30 || true
  if wait_interactive 120; then
    echo "relaunch -> interactive: $(since $T2) s wall"
  else
    echo "relaunch -> not interactive within 120 s"
  fi
  tail -n +$MARK $LOG | grep -oE 'restore: [a-z ]+\+[0-9]+ ms|state loaded in [0-9]+ ms' | sed 's/^/  /'
  xcrun simctl io $UDID screenshot $OUT/round$r-restored.png >/dev/null 2>&1 || true
  [[ $ENGINE == qemu ]] && echo "  adb: $(adb_focus | sed 's/^ *//')"
  sleep 5
done
