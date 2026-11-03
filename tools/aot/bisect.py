#!/usr/bin/env python3
"""Bisect the AOT table for an entry that breaks the boot.

  bisect.py CAPTURE.txt LIB [--pc kernel|user]

Uses QEMU_AOT_KEYRANGE to enable a key range and tools/aot/try-boot.sh as the
oracle.  Assumes a single culprit; reports when both halves pass.
"""
import argparse, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def keys_of(capture, pc):
    ks = []
    with open(capture) as f:
        for line in f:
            if line.startswith("TB "):
                h = dict(kv.split("=", 1) for kv in line.split()[1:])
                k = int(h["pc"], 16) >> 63
                if pc == "kernel" and not k or pc == "user" and k:
                    continue
                ks.append(int(h["key"], 16))
    return sorted(set(ks))


def run(lib, lo, hi, pc):
    env = [f"QEMU_AOT_KEYRANGE={lo:x}-{hi:x}"]
    if pc:
        env.append(f"QEMU_AOT_PC={pc}")
    r = subprocess.run([os.path.join(HERE, "try-boot.sh"), lib] + env, capture_output=True, text=True)
    ok = r.stdout.strip().startswith("PASS")
    print(f"  [{lo:016x}-{hi:016x}] {'PASS' if ok else 'FAIL'}", flush=True)
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("lib")
    ap.add_argument("--pc")
    a = ap.parse_args()
    ks = keys_of(a.capture, a.pc)
    print(f"{len(ks)} candidate keys")
    lo, hi = 0, len(ks) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if not run(a.lib, ks[lo], ks[mid], a.pc):
            hi = mid
        elif not run(a.lib, ks[mid + 1], ks[hi], a.pc):
            lo = mid + 1
        else:
            print(f"both halves pass: interaction within [{ks[lo]:016x}-{ks[hi]:016x}] ({hi - lo + 1} keys)")
            return
    print(f"culprit key: {ks[lo]:016x}")
    run(a.lib, ks[lo], ks[lo], a.pc)


if __name__ == "__main__":
    main()
