#!/usr/bin/env python3
"""Prototype check of the same-ISA passthrough table (docs/AOT.md).

  tools/aot/tests/pt-proto-check.py [--qemu-src engine/qemu-aot] [--cc clang]
                                    [--cflags "-target ..."]

For every helper in tcg2c.py's PASSTHROUGH table, read its DEF_HELPER
declaration from the QEMU sources (target/arm/helper.h, tcg/helper-a64.h,
accel/tcg/tcg-runtime.h), emit the exact call forms tcg2c.py's gen_pt()
generates for it (same C argument and result types, from the TCG type
codes), and compile them against aot_rt.h with pointer/integer conversion
warnings as errors.  The generated cache itself is compiled with -w, so a
wrong out-pointer type (uint32_t vs uint64_t result), a missing or extra
argument or a void/non-void mix-up would otherwise only show up as a silent
miscompile.  Also checks that the table only names helpers that exist, that
the fallible ones return int and that gvec ones take the descriptor last.
Exit status 0 when everything compiles.
"""
import argparse, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AOT = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(AOT))
sys.path.insert(0, AOT)
import tcg2c  # noqa: E402

TYPECODE = {"void": 0, "noreturn": 0, "i32": 2, "s32": 3, "int": 3, "f16": 2, "f32": 2,
            "i64": 4, "s64": 5, "f64": 4, "ptr": 6, "cptr": 6, "env": 6, "fpst": 6, "i128": 7}
CTYPE = {2: "uint32_t", 3: "uint32_t", 4: "uint64_t", 5: "uint64_t", 6: "uint64_t"}


def helpers(src):
    decl = {}
    for rel in ("target/arm/helper.h", "target/arm/tcg/helper-a64.h", "accel/tcg/tcg-runtime.h"):
        text = open(os.path.join(src, rel)).read()
        for m in re.finditer(r"^DEF_HELPER_(FLAGS_)?(\d)\(([^)]*)\)", text, re.M | re.S):
            parts = [p.strip() for p in m.group(3).replace("\\\n", " ").split(",")]
            if "##" in parts[0]:
                continue
            name = parts[0]
            rest = parts[2:] if m.group(1) else parts[1:]
            decl[name] = (rest[0], rest[1:])
    return decl


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu-src", default=os.path.join(ROOT, "engine", "qemu-aot"))
    ap.add_argument("--cc", default="clang")
    ap.add_argument("--cflags", default="")
    a = ap.parse_args()
    decl = helpers(a.qemu_src)
    bad = []
    out = ["#include <stdint.h>", "#include <string.h>", '#include "aot_rt.h"', "int aot_pt_on;",
           "uint64_t aot_pt_cnt[1][2];"]
    for i, (h, (fallible, oprsz_ok, consts)) in enumerate(sorted(tcg2c.PASSTHROUGH.items())):
        if h not in decl:
            bad.append(f"{h}: no DEF_HELPER in {a.qemu_src}")
            continue
        ret, args = decl[h]
        rc = TYPECODE[ret]
        codes = [TYPECODE[t] for t in args]
        if 7 in codes or rc == 7:
            bad.append(f"{h}: i128 (gen_pt never passes it through)")
            continue
        if oprsz_ok is not None and (codes[-1] != 2 or args[-1] != "i32"):
            bad.append(f"{h}: gvec entry but last argument is {args[-1]}, not the i32 desc")
        for j in (consts or {}):
            if j >= len(codes):
                bad.append(f"{h}: const_args index {j} out of range")
        params = ", ".join(f"{CTYPE[c]} a{k}" for k, c in enumerate(codes))
        pargs = ", ".join(f"PTR(a{k})" if c == 6 else f"a{k}" for k, c in enumerate(codes))
        fn = f"aot_pt_{h}"
        out.append(f"/* {h}: {ret} ({', '.join(args)}), {'fallible' if fallible else 'infallible'} */")
        if rc == 0:
            out.append(f"int t{i}({params}) {{")
            if fallible:
                out.append(f"  _Static_assert(__builtin_types_compatible_p(__typeof__({fn}({pargs})), int), \"{h}\");")
                out.append(f"  return {fn}({pargs});")
            else:
                out.append(f"  _Static_assert(__builtin_types_compatible_p(__typeof__({fn}({pargs})), void), \"{h}\");")
                out.append(f"  {fn}({pargs}); return 1;")
        else:
            rt = CTYPE[rc]
            out.append(f"{rt} t{i}({params}) {{")
            if fallible:
                out.append(f"  {rt} r_;")
                out.append(f"  _Static_assert(__builtin_types_compatible_p(__typeof__({fn}(&r_, {pargs})), int), \"{h}\");")
                out.append(f"  return {fn}(&r_, {pargs}) ? r_ : 0;")
            else:
                out.append(f"  return ({rt}){fn}({pargs});")
        out.append("}")
    with tempfile.TemporaryDirectory() as d:
        c = os.path.join(d, "pt_proto.c")
        open(c, "w").write("\n".join(out) + "\n")
        cmd = [a.cc] + a.cflags.split() + [
            "-c", "-o", os.path.join(d, "pt_proto.o"), "-O2", "-mcrc", "-ffp-contract=off", "-I" + AOT, "-DAOT_PAGE_BITS=12",
            "-Werror=incompatible-pointer-types", "-Werror=int-conversion",
            "-Werror=implicit-function-declaration", "-Werror=incompatible-function-pointer-types",
            "-Werror=pointer-sign", "-Wno-unused-value", c]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            bad.append("compile failed:\n" + r.stderr[-4000:])
    print(f"pt-proto-check: {len(tcg2c.PASSTHROUGH)} table entries, {len(bad)} problems")
    for b in bad:
        print("  " + b)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
