#!/bin/zsh
# Boot the ranchu machine with a given QEMU and wait for sys.boot_completed=1.
#   tools/aot/boot-completed-check.sh QEMU [NAME] [ADB_PORT] [TIMEOUT_SECS]
# Prints progress (guest milestones, zygote deaths) and exits 0 on boot_completed,
# 1 on timeout / repeated zygote deaths, 2 when stopped for .logs/HOLD_VMS.
ROOT=${0:A:h:h:h}
QEMU=${1:?qemu binary}
NAME=${2:-tcti-repro}
PORT=${3:-5671}
TIMEOUT=${4:-2400}
HOLD=$ROOT/.logs/HOLD_VMS
RUN=$ROOT/engine/run/$NAME
ADB=${ADB:-adb}
while [[ -e $HOLD ]]; do echo "HOLD_VMS present, waiting"; sleep 20; done
rm -f $RUN/serial.log $RUN/logcat.log
QEMU=$QEMU $ROOT/tools/run-macos.sh --fresh --tcg --machine ranchu --name $NAME --adb-port $PORT \
  --timeout $((TIMEOUT + 60)) > $ROOT/.logs/aot-$NAME-run.log 2>&1 &
T0=$SECONDS
stop() { pkill -f "engine/run/$NAME/" ; sleep 3; pkill -9 -f "engine/run/$NAME/" 2>/dev/null; true; }
rc=1
while (( SECONDS - T0 < TIMEOUT )); do
  sleep 20
  t=$((SECONDS - T0))
  if [[ -e $HOLD ]]; then echo "[$t s] HOLD_VMS appeared, stopping"; stop; exit 2; fi
  died=$(grep -c "System zygote died" $RUN/logcat.log 2>/dev/null)
  preload=$(grep -c "begin preload" $RUN/logcat.log 2>/dev/null)
  done_preload=$(grep -c "end preload" $RUN/logcat.log 2>/dev/null)
  ss=$(grep -c "Entered the Android system server" $RUN/logcat.log 2>/dev/null)
  $ADB connect 127.0.0.1:$PORT > /dev/null 2>&1
  bc=$($ADB -s 127.0.0.1:$PORT shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  echo "[$t s] preload=$preload end_preload=$done_preload zygote_died=$died system_server=$ss boot_completed=${bc:-?}"
  if [[ $bc == 1 ]]; then echo "BOOT_COMPLETED after $t s (zygote died $died times)"; rc=0; break; fi
  if (( died >= 3 )); then echo "FAIL: zygote died $died times"; break; fi
done
stop
exit $rc
