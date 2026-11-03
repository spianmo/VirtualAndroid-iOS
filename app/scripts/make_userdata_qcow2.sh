#!/bin/zsh
# Builds the writable disks the iOS app needs (iOS has no mke2fs):
#   userdata.qcow2   freshly formatted ext4, label "data"  (default 6G)
#   cache.qcow2      freshly formatted ext4, label "cache" (64M)
# and, with --pack, a complete image pack folder for the app.
#
#   app/scripts/make_userdata_qcow2.sh [-o OUTDIR] [--size 6G] [--pack [IMAGE_DIR]]
#
#   -o OUTDIR      output folder (default: <repo>/app/build/ImagePack)
#   --size SIZE    userdata size for mkfile (default 6g)
#   --pack [DIR]   also add kernel-ranchu, ramdisk.img, system.img, vendor.img
#                  (APFS clones via cp -c, no extra disk space on the same
#                  volume) and encryptionkey.qcow2 from the Android image
#                  (default: <repo>/images/android-33/arm64-v8a), plus manifest.json
#
# Tools: engine/build-macos/qemu-img (QEMU_IMG overrides) and e2fsprogs
# (brew install e2fsprogs). Inode tables and journal are zeroed on the host
# (lazy init off) so the guest does not rewrite them on first boot and the
# qcow2 stays small (zero clusters are not stored).
set -euo pipefail
ROOT=${0:A:h:h:h}
OUT=$ROOT/app/build/ImagePack
SIZE=6g
PACK=0
IMG=$ROOT/images/android-33/arm64-v8a
QEMU_IMG=${QEMU_IMG:-$ROOT/engine/build-macos/qemu-img}
E2=$(brew --prefix e2fsprogs)/sbin

while (( $# )); do
  case $1 in
    -o) OUT=$2; shift ;;
    --size) SIZE=$2; shift ;;
    --pack) PACK=1; if [[ $# -gt 1 && $2 != -* ]]; then IMG=$2; shift; fi ;;
    -h|--help) sed -n '2,20p' $0; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -x $QEMU_IMG ]] || { echo "qemu-img not found at $QEMU_IMG (set QEMU_IMG)" >&2; exit 1; }
[[ -x $E2/mke2fs ]] || { echo "mke2fs not found; brew install e2fsprogs" >&2; exit 1; }
mkdir -p $OUT
TMP=$(mktemp -d $OUT/.mkdisk.XXXXXX)
trap 'rm -rf $TMP' EXIT

make_ext4() {  # name label size
  local raw=$TMP/$1.raw
  mkfile -n $3 $raw
  $E2/mke2fs -q -F -t ext4 -b 4096 -L $2 -E lazy_itable_init=0,lazy_journal_init=0 $raw
  $E2/e2fsck -fn $raw >/dev/null
  $QEMU_IMG convert -q -f raw -O qcow2 -o cluster_size=65536 $raw $OUT/$1.qcow2
  rm -f $raw
  echo "$OUT/$1.qcow2: $($QEMU_IMG info --output=json $OUT/$1.qcow2 | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["virtual-size"]//2**20, "MiB virtual,", d["actual-size"]//2**10, "KiB on disk")')"
}

make_ext4 userdata data $SIZE
make_ext4 cache cache 64m

if (( PACK )); then
  for f in kernel-ranchu ramdisk.img system.img vendor.img; do
    [[ -f $IMG/$f ]] || { echo "missing $IMG/$f" >&2; exit 1; }
    rm -f $OUT/$f
    cp -c $IMG/$f $OUT/$f 2>/dev/null || cp $IMG/$f $OUT/$f
  done
  for f in VerifiedBootParams.textproto build.prop; do
    [[ -f $IMG/$f ]] && cp $IMG/$f $OUT/$f
  done
  # Metadata partition as qcow2 too: every writable disk must support savevm.
  $QEMU_IMG convert -q -f raw -O qcow2 $IMG/encryptionkey.img $OUT/encryptionkey.qcow2
  rm -f $OUT/encryptionkey.img
  REV=$(sed -n 's/^Pkg.Revision=//p' $IMG/source.properties 2>/dev/null || true)
  cat > $OUT/manifest.json <<JSON
{
  "name": "Android 13 (AOSP)",
  "api": 33,
  "abi": "arm64-v8a",
  "revision": "${REV:-unknown}",
  "userdata_size": "$SIZE",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
  echo "image pack ready: $OUT"
  ls -lh $OUT
fi
