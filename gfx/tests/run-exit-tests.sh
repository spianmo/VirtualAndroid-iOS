#!/bin/bash
# Run the harness in each shutdown mode with a watchdog; a hang counts as failure.
# usage: run-exit-tests.sh <macos|ios-sim> [sim-udid]
set -uo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-macos}"; UDID="${2:-booted}"
B="$GFX/build-$PLATFORM"; mkdir -p "$B/out"
LOGDIR="$(cd "$GFX/.." && pwd)/.logs"
rc=0
for mode in "" live live-busy teardown-open; do
  log="$LOGDIR/gfx-exit-$PLATFORM-${mode:-closed}.log"
  if [ "$PLATFORM" = macos ]; then
    HARNESS_EXIT="$mode" "$B/tests/va_gfx_harness" "$B/dist/libva_gfx.dylib" "$B/out" angle >"$log" 2>&1 &
  else
    SIMCTL_CHILD_HARNESS_EXIT="$mode" xcrun simctl spawn "$UDID" "$B/tests/va_gfx_harness" \
      "$B/dist/va_gfx.framework/va_gfx" "$B/out" angle >"$log" 2>&1 &
  fi
  pid=$!; t=0
  while kill -0 $pid 2>/dev/null && [ $t -lt 60 ]; do sleep 0.5; t=$((t+1)); done
  if kill -0 $pid 2>/dev/null; then
    echo "mode=${mode:-closed}: HUNG (killing)"; kill -9 $pid; pkill -9 -f "$B/tests/va_gfx_harness" 2>/dev/null; rc=1
  else
    wait $pid; st=$?
    echo "mode=${mode:-closed}: exit status $st after ~$((t/2))s; $(grep -E 'HARNESS|exit:' "$log" | tr '\n' ' ')"
    [ $st -eq 0 ] || rc=1
  fi
done
exit $rc
