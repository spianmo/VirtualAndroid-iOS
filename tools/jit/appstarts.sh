#!/bin/bash
# Cold-start timings of a few apps in the guest over adb (am start -W TotalTime)
# and a Settings scroll frame-stats sample, each from a quiet guest: every
# third-party app force-stopped, then wait until the 1-min load average is low
# (or 90 s). usage: appstarts.sh SERIAL LABEL OUTDIR
S=$1; L=$2; OUT=$3
mkdir -p "$OUT"
A="adb -s $S"
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$OUT/$L.txt"; }
third=$($A shell pm list packages -3 | tr -d '\r' | sed 's/package://')
quiet() {
    for p in $third; do $A shell am force-stop $p; done
    local n=0 la
    while [ $n -lt 45 ]; do
        la=$($A shell cat /proc/loadavg | awk '{print $1}')
        awk -v l="$la" 'BEGIN{exit !(l < 3.0)}' && break
        sleep 2; n=$((n+1))
    done
    log "quiet: load $($A shell cat /proc/loadavg | cut -d' ' -f1-3) after $((n*2)) s; $($A shell free -m | awk '/Mem:/{print "used "$3" MB"} /Swap:/{print "swap "$3" MB"}' | tr '\n' ' ')"
}
log "== $L"
log "uptime $($A shell cat /proc/uptime) boot_completed=$($A shell getprop sys.boot_completed)"
apps="com.android.settings/.Settings com.android.deskclock/.DeskClock com.android.calendar/.AllInOneActivity com.android.dialer/.main.impl.MainActivity"
for pkg in $third; do
    act=$($A shell cmd package resolve-activity --brief $pkg 2>/dev/null | tail -1 | tr -d '\r')
    case "$act" in */*) apps="$apps $act" ;; esac
done
# UI smoothness first, from a quiet guest
quiet
$A shell am start -W -n com.android.settings/.Settings >/dev/null 2>&1
sleep 4
$A shell dumpsys gfxinfo com.android.settings reset >/dev/null 2>&1
for i in 1 2 3 4 5 6; do $A shell input swipe 540 1800 540 600 300; sleep 1; $A shell input swipe 540 600 540 1800 300; sleep 1; done
$A shell dumpsys gfxinfo com.android.settings | grep -E 'Total frames rendered|Janky frames:|50th percentile|90th percentile|99th percentile' | while read -r l; do log "settings scroll: $l"; done
$A shell input keyevent KEYCODE_HOME
for a in $apps; do
    p=${a%%/*}
    $A shell am force-stop $p
    quiet
    r=$($A shell am start -W -n "$a" 2>&1 | tr -d '\r' | grep -E 'TotalTime|WaitTime|Status' | tr '\n' ' ')
    log "$a: $r"
    sleep 8
    $A shell input keyevent KEYCODE_HOME
done
for p in $third; do $A shell am force-stop $p; done
log "done"
