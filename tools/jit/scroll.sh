#!/bin/bash
# Settings scroll frame stats from a quiet guest. usage: scroll.sh SERIAL OUTFILE
S=$1; A="adb -s $S"
for p in $($A shell pm list packages -3 | tr -d '\r' | sed 's/package://'); do $A shell am force-stop $p; done
n=0; while [ $n -lt 60 ]; do la=$($A shell cat /proc/loadavg | awk '{print $1}'); awk -v l="$la" 'BEGIN{exit !(l < 2.0)}' && break; sleep 3; n=$((n+1)); done
echo "load $($A shell cat /proc/loadavg)" | tee "$2"
$A shell am start -W -n com.android.settings/.Settings >/dev/null 2>&1; sleep 4
$A shell dumpsys gfxinfo com.android.settings reset >/dev/null 2>&1
for i in 1 2 3 4 5 6; do $A shell input swipe 540 1800 540 600 300; sleep 1; $A shell input swipe 540 600 540 1800 300; sleep 1; done
$A shell dumpsys gfxinfo com.android.settings | grep -E 'Total frames rendered|Janky frames:|50th percentile|90th percentile|99th percentile' | tee -a "$2"
$A shell input keyevent KEYCODE_HOME
