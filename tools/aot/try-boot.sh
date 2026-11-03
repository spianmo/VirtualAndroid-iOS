#!/bin/zsh
# tools/aot/try-boot.sh LIB [ENV=VAL ...]: short TCTI+AOT boot to init second
# stage; prints PASS/FAIL (kernel panic or milestone missing).
ROOT=${0:A:h:h:h}
LIB=$1; shift
ENVS=()
for kv in "$@"; do ENVS+=(--env $kv); done
rm -rf $ROOT/engine/run/aot-try
python3 -I $ROOT/tools/aot/boot-bench.py --qemu $ROOT/engine/build-macos-aot-tcti/qemu-system-aarch64 \
  --name aot-try --timeout ${TRY_TIMEOUT:-45} --stop-after ${TRY_STOP:-second_stage} --linger ${TRY_LINGER:-3} \
  --env QEMU_AOT_LIB=$LIB $ENVS > /tmp/aot-try.out 2>&1
if grep -q "Kernel panic" $ROOT/engine/run/aot-try/serial.log || ! grep -q "${TRY_PAT:-second stage started}" $ROOT/engine/run/aot-try/serial.log; then
  echo FAIL; else echo PASS; fi
grep -h "milestones" /tmp/aot-try.out | cut -c1-300 >&2
