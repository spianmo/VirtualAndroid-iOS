#!/bin/bash
# Cross-process snapshot round trips: A renders + saves + exits; B loads in a
# fresh process, re-presents the last frame (pixel-identical), keeps driving
# the same guest command stream; B also suspends again into a second dir and
# C restores that. usage: run-snapshot-tests.sh <macos|ios-sim> [sim-udid] [WxH]
set -uo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-macos}"; UDID="${2:-booted}"; SIZE="${3:-1080x2340}"
B="$GFX/build-$PLATFORM"; LOG="$(cd "$GFX/.." && pwd)/.logs"
D1=$(mktemp -d /tmp/vagfx-snapA.XXXXXX); D2=$(mktemp -d /tmp/vagfx-snapB.XXXXXX)
W=${SIZE%x*}; H=${SIZE#*x}
if [ "$PLATFORM" = macos ]; then LIB="$B/dist/libva_gfx.dylib"; else LIB="$B/dist/va_gfx.framework/va_gfx"; fi
run() { # name mode dir [resave]
  local log="$LOG/gfx-snapshot-$PLATFORM-$1.log"
  if [ "$PLATFORM" = macos ]; then
    HARNESS_W=$W HARNESS_H=$H HARNESS_SNAPSHOT=$2 HARNESS_SNAPDIR=$3 HARNESS_SNAPSHOT_RESAVE=${4:-} \
      "$B/tests/va_gfx_harness" "$LIB" "$B/out" angle >"$log" 2>&1 &
  else
    SIMCTL_CHILD_HARNESS_W=$W SIMCTL_CHILD_HARNESS_H=$H SIMCTL_CHILD_HARNESS_SNAPSHOT=$2 \
      SIMCTL_CHILD_HARNESS_SNAPDIR=$3 SIMCTL_CHILD_HARNESS_SNAPSHOT_RESAVE=${4:-} \
      xcrun simctl spawn "$UDID" "$B/tests/va_gfx_harness" "$LIB" "$B/out" angle >"$log" 2>&1 &
  fi
  local pid=$! t=0
  while kill -0 $pid 2>/dev/null && [ $t -lt 240 ]; do sleep 0.5; t=$((t+1)); done
  if kill -0 $pid 2>/dev/null; then kill -9 $pid; echo "$1: HUNG"; return 1; fi
  wait $pid; local st=$?
  echo "$1: exit $st"
  grep -E "va_gfx: snapshot (save|load)|snapshot (save|load) \(|snapshot load:|re-presented|redone|GLES draw|restored buffers|FAIL|HARNESS" "$log" | sed 's/^/    /' | cut -c1-240
  return $st
}
rc=0
run A save "$D1" || rc=1
run B load "$D1" "$D2" || rc=1
run C load "$D2" || rc=1
echo "aux dirs: A $(du -sh "$D1" | cut -f1) (gfx-textures.bin $(stat -f %z "$D1/gfx-textures.bin") B), B $(du -sh "$D2" | cut -f1)"
rm -rf "$D1" "$D2"
exit $rc
