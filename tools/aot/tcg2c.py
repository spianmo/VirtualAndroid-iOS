#!/usr/bin/env python3
"""TCG ops -> C translator for the VirtualAndroid AOT cache.

Input: an op capture produced by QEMU with QEMU_AOT_CAPTURE (see
engine/qemu-aot/tcg/aot.c): the optimized, liveness-annotated TCG op list of
each hot TB plus its content key and op fingerprint.

Output (in --out DIR): aot_gen_NNN.c (one C function per TB), aot_table.c
(sorted key table + helper binding table) and a build.ninja that compiles
them with clang -O2 into libaot.dylib (production) and libaot-verify.dylib
(production + journaled verification variants).

  tcg2c.py CAPTURE.txt --out DIR [--per-file 300] [--max N] [--prof prof.tsv]
           [--qemu BIN] [--cc CC] [--cflags FLAGS] [--ldflags FLAGS]
           [--no-passthrough] [--pt-fpsr] [--pt-stats]

--cc/--cflags/--ldflags cross-compile the cache (engine/scripts/ios/build_aot.sh
passes the iOS / iOS Simulator toolchain); the default is the host clang.

Same-ISA passthrough (default on, docs/AOT.md): FP, crypto, CRC and some
integer/Neon helper calls become inline host instructions (aot_rt.h,
aot_pt_*); --no-passthrough generates the plain helper calls (A/B).
--pt-fpsr also passes through rounding FP ops while Inexact is still clear,
using the host FPSR; --pt-stats counts inline hits and fallbacks per helper
and prints them at exit when AOT_PT_STATS is set in the environment.
"""
import argparse, collections, os, re, sys

U = {32: "uint32_t", 64: "uint64_t"}
S = {32: "int32_t", 64: "int64_t"}
SH = {32: 31, 64: 63}
BI = {32: "", 64: "ll"}

# Helpers whose effects cannot be rolled back / replayed by the verifier
# (memory side effects, device or timer state, nondeterministic reads).
UNSAFE_HELPER = re.compile(
    r"(atomic|cmpxchg|exclusive|cp_reg|sysreg|tlbi|zva|mte|probe|wfi|wfe|yield|"
    r"pmu|exception_return|eret|hvc|smc|^(sve_|sme_)?(ld|st)|ldst|gt_|timer|cnt|"
    r"rndr|dc_|lookup_tb|exit_atomic|vesb|pre_|guarded|cache)")

LDST_SYMS = ["helper_ldub_mmu", "helper_lduw_mmu", "helper_ldul_mmu", "helper_ldq_mmu",
             "helper_stb_mmu", "helper_stw_mmu", "helper_stl_mmu", "helper_stq_mmu"]


# Same-ISA passthrough (aot_rt.h, "Same-ISA passthrough"): helper name ->
# (fallible, oprsz_allowed, const_args).  Fallible ones return 0 from
# aot_pt_<helper>() when they cannot prove a bit-identical result, and the
# generated code then calls the helper.  oprsz_allowed (gvec helpers): the
# descriptor (last argument) must be a TB constant with maxsz 16 and one of
# these oprsz.  const_args: {arg index: allowed constant values}.
def _pt_table():
    t = {}
    F, I = True, False
    V, Q = (8, 16), (16,)
    for p in "sd":
        for op in ("add", "sub", "mul", "div", "min", "max", "minnum", "maxnum", "muladd", "sqrt"):
            t[f"vfp_{op}{p}"] = (F, None, None)
        for n in (f"vfp_cmp{p}_a64", f"vfp_cmpe{p}_a64", f"rint{p}", f"rint{p}_exact"):
            t[n] = (F, None, None)
        for i in ("sl", "ul", "sq", "uq", "si", "ui"):
            t[f"vfp_{i}to{p}"] = (F, None, None)
        for i in ("sl", "ul", "sq", "uq"):
            t[f"vfp_to{i}{p}"] = (F, None, None)
            if p == "d" or i in ("sl", "ul"):     # no vfp_to{sq,uq}s_round_to_zero
                t[f"vfp_to{i}{p}_round_to_zero"] = (F, None, None)
        for i in ("si", "ui", "siz", "uiz"):
            t[f"vfp_to{i}{p}"] = (F, None, None)
    t["vfp_fcvtds"] = t["vfp_fcvtsd"] = (F, None, None)
    t["set_rmode"] = (I, None, None)
    for p, sz in (("s", V), ("d", Q)):
        for op in ("fadd", "fsub", "fmul", "fdiv", "fmin", "fmax", "fminnum", "fmaxnum",
                   "fceq", "fcge", "fcgt", "fceq0", "fcgt0", "fcge0", "fclt0", "fcle0",
                   "fmul_idx", "vfma", "vfms", "fmla_idx", "fmls_idx"):
            t[f"gvec_{op}_{p}"] = (F, sz, None)
    for n, sz in (("sf", V), ("uf", V), ("sd", Q), ("ud", Q), ("rz_fs", V), ("rz_fu", V),
                  ("rm_ss", V), ("rm_us", V), ("rz_ds", Q), ("rz_du", Q), ("rm_sd", Q),
                  ("rm_ud", Q)):
        t[f"gvec_vcvt_{n}"] = (F, sz, None)
    for n in ("muluh_i64", "mulsh_i64", "udiv64", "sdiv64", "rbit", "rbit64",
              "neon_narrow_u8", "neon_narrow_u16", "neon_widen_u8", "neon_widen_u16",
              "neon_clz_u16"):
        t[n] = (I, None, None)
    t["crc32c_64"] = (I, None, {2: (1, 2, 4, 8)})
    t["crc32_64"] = (F, None, {2: (1, 2, 4, 8)})
    for n in ("aese", "aesd", "aesmc", "aesimc", "sha256h", "sha256h2", "sha256su0", "sha256su1"):
        t[f"crypto_{n}"] = (I, Q, None)
    for op in ("addp", "smaxp", "umaxp", "sminp", "uminp"):
        for e in "bhs":
            t[f"gvec_{op}_{e}"] = (I, V, None)
    t["gvec_addp_d"] = (I, Q, None)
    t["gvec_cnt_b"] = t["gvec_rbit_b"] = (I, V, None)
    return t


PASSTHROUGH = _pt_table()


class Unsupported(Exception):
    pass


def s64(v):
    v = int(v, 16)
    return v - (1 << 64) if v >= (1 << 63) else v


def parse(path):
    layout = {}
    tbs = []
    cur = None
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("LAYOUT "):
                for kv in line.split()[1:]:
                    k, v = kv.split("=", 1)
                    layout[k] = v
            elif line.startswith("TB "):
                hdr = dict(kv.split("=", 1) for kv in line.split()[1:])
                cur = {"hdr": hdr, "temps": {}, "ops": []}
            elif line == "END":
                if cur:
                    tbs.append(cur)
                cur = None
            elif cur is None:
                continue
            elif line.startswith("T "):
                p = line.split()
                cur["temps"][int(p[1])] = p[2:]
            elif line.startswith("O "):
                if line.count("|") != 2:   # truncated tail of a killed run
                    cur = None
                    continue
                head, targs, cargs = line[2:].split("|")
                h = head.split()
                cur["ops"].append((h[0], int(h[1]), int(h[2]), int(h[3]), int(h[4]),
                                   [int(x) for x in targs.split()], cargs.split()))
    return layout, tbs


class Gen:
    def __init__(self, layout, syms=None, tlb_base=None, ld128_off=None, passthrough=True):
        self.syms = syms
        self.passthrough = passthrough
        self.pt_ids = collections.OrderedDict()   # helper -> stats slot
        self.pt_static = collections.Counter()    # inlined call sites
        self.tlb_base = tlb_base          # TLB mask/table offset of mmu_idx 0
        self.ld128_off = ld128_off or {}
        self.helpers = collections.OrderedDict()  # (name, off) -> index
        ldst = [int(x) for x in layout["ldst"].split(",")]
        for sym, off in zip(LDST_SYMS, ldst):
            self.helpers[(sym, off)] = len(self.helpers)
        self.unsupported = collections.Counter()

    def helper(self, sym, off):
        k = (sym, off)
        if k not in self.helpers:
            self.helpers[k] = len(self.helpers)
        return self.helpers[k]

    def inline_i128(self, hname, no, ni, ta, temps, ex, E, ra):
        """Inline softmmu fast path for helper_ld_i128 / helper_st_i128 (LDP/STP
        of X registers).  Only for MO_ATOM_IFALIGN_PAIR / MO_ATOM_NONE little
        endian accesses, where two 8-byte host accesses (single-copy atomic
        when 8-byte aligned) give the required atomicity.  Slow path: the
        same helper."""
        oit = ta[no + ni - 1]
        d = temps[oit]
        if d[0] != "K" or self.tlb_base is None:
            return False
        oi = int(d[3], 16)
        mop, mmu = oi >> 4, oi & 15
        if (mop & 7) != 4 or (mop & 0x10) or (mop & 0x700) not in (0x100, 0x500):
            return False
        a = mop & 0xe0
        ab = 0 if a == 0 else (4 if a == 0xe0 else a >> 5)
        ofs = self.tlb_base + 16 * mmu
        if hname == "st_i128":
            k = self.helper("helper_st_i128", self.ld128_off["st"])
            addr, lo, hi = ex(ta[no + 1]), ex(ta[no + 2]), ex(ta[no + 3])
            E(f"  {{ uint64_t a_ = {addr}, lo_ = {lo}, hi_ = {hi}; uintptr_t h_ = aot_tlb(env, a_, {ofs}, 1, 4, {ab});")
            E(f"    if (likely(h_)) {{ RT_JOURNAL(h_, 16); memcpy((void *)h_, &lo_, 8); memcpy((void *)(h_ + 8), &hi_, 8); }}")
            E(f"    else {{ *ra = {ra}; RT_SLOW_BEGIN(); ((void (*)(void *, uint64_t, __uint128_t, uint32_t))"
              f"H({k}, helper_st_i128))(env, a_, (__uint128_t)hi_ << 64 | lo_, 0x{oi:x}u); RT_SLOW_END(0); }} }}")
        else:
            k = self.helper("helper_ld_i128", self.ld128_off["ld"])
            addr = ex(ta[no + 1])
            E(f"  {{ uint64_t a_ = {addr}, lo_, hi_; uintptr_t h_ = aot_tlb(env, a_, {ofs}, 0, 4, {ab});")
            E(f"    if (likely(h_)) {{ memcpy(&lo_, (void *)h_, 8); memcpy(&hi_, (void *)(h_ + 8), 8); }}")
            E(f"    else {{ *ra = {ra}; RT_SLOW_BEGIN(); __uint128_t r_ = ((__uint128_t (*)(void *, uint64_t, uint32_t))"
              f"H({k}, helper_ld_i128))(env, a_, 0x{oi:x}u); lo_ = (uint64_t)r_; hi_ = (uint64_t)(r_ >> 64);"
              f" RT_SLOW_END(aot_tlb(env, a_, {ofs}, 0, 4, {ab}) != 0); }}")
            E(f"    {ex(ta[0])} = lo_; {ex(ta[1])} = hi_; }}")
        return True

    def gen_pt(self, hname, ret, rt, no, codes, args, ta, temps, ex, width, E, ra, callx):
        """Same-ISA passthrough of one helper call (aot_rt.h, aot_pt_*).
        Returns False when the call must stay a plain helper call."""
        ent = PASSTHROUGH.get(hname) if self.passthrough else None
        if ent is None or 7 in codes or ret == 7 or no > 1 or (ret == 0) != (no == 0):
            return False
        fallible, oprsz_ok, consts = ent
        ins = ta[no:]
        def const(j):
            d = temps[ins[j]]
            return int(d[3], 16) if d[0] == "K" else None
        if oprsz_ok is not None:
            desc = const(len(codes) - 1)
            if desc is None:
                return False
            maxsz = (desc & 0xff) * 8 + 8
            f = (desc >> 8) & 3
            oprsz = maxsz if f == 2 else f * 8 + 8
            if maxsz != 16 or oprsz not in oprsz_ok:
                return False
        for j, ok in (consts or {}).items():
            if const(j) not in ok:
                return False
        if hname not in self.pt_ids:
            self.pt_ids[hname] = len(self.pt_ids)
        sid = self.pt_ids[hname]
        self.pt_static[hname] += 1
        pargs = [f"PTR({a})" if c == 6 else a for a, c in zip(args, codes)]
        fn = f"aot_pt_{hname}"
        if not fallible:
            E(f"  AOT_PT_HIT({sid});")
            if ret == 0:
                E(f"  {fn}({', '.join(pargs)});")
            else:
                E(f"  {ex(ta[0])} = ({U[width(ta[0])]}){fn}({', '.join(pargs)});")
            return True
        if ret == 0:
            E(f"  if (likely({fn}({', '.join(pargs)}))) {{ AOT_PT_HIT({sid}); }}")
            E(f"  else {{ AOT_PT_MISS({sid}); *ra = {ra}; {callx}; }}")
        else:
            E(f"  {{ {rt} r_; if (likely({fn}(&r_, {', '.join(pargs)}))) {{ AOT_PT_HIT({sid}); }}")
            E(f"    else {{ AOT_PT_MISS({sid}); *ra = {ra}; r_ = {callx}; }}")
            E(f"    {ex(ta[0])} = ({U[width(ta[0])]})r_; }}")
        return True

    def gen_vec(self, op, ty, vece, no, ni, ta, ca, ex, base, E):
        if ty not in (3, 4):
            raise Unsupported(f"vector type {ty}")
        q = 1 if ty == 4 else 0
        bits = 8 << vece
        VT, ST = f"aot_u{bits}", f"aot_s{bits}"
        lane = {8: "uint8_t", 16: "uint16_t", 32: "uint32_t", 64: "uint64_t"}[bits]
        o = [ex(t) for t in ta[:no]]
        i = [ex(t) for t in ta[no:]]
        R = lambda e: f"  {o[0]} = (aot_v128)({e});"
        BINV = {"add": "+", "sub": "-", "mul": "*"}
        LOG = {"and": "{a} & {b}", "or": "{a} | {b}", "xor": "{a} ^ {b}", "andc": "{a} & ~{b}",
               "orc": "{a} | ~{b}", "nand": "~({a} & {b})", "nor": "~({a} | {b})", "eqv": "~({a} ^ {b})"}
        if op == "ld":
            E(f"  {o[0]} = aot_vld({base(ta[no])} + {s64(ca[0])}, {q});")
        elif op == "st":
            E(f"  aot_vst({base(ta[1])} + {s64(ca[0])}, {i[0]}, {q});")
        elif op == "mov":
            E(f"  {o[0]} = {i[0]};")
        elif op == "dup":
            E(R(f"({VT}){{0}} + ({lane})({i[0]})"))
        elif op == "dupm":
            E(R(f"({VT}){{0}} + *({lane} *)({base(ta[no])} + {s64(ca[0])})"))
        elif op in BINV:
            E(R(f"({VT})({i[0]}) {BINV[op]} ({VT})({i[1]})"))
        elif op in LOG:
            E(R(LOG[op].format(a=f"({i[0]})", b=f"({i[1]})")))
        elif op == "not":
            E(R(f"~({i[0]})"))
        elif op == "neg":
            E(R(f"-({VT})({i[0]})"))
        elif op == "abs":
            E(R(f"__builtin_elementwise_abs(({ST})({i[0]}))"))
        elif op in ("shli", "shri", "sari"):
            n = int(ca[0], 16)
            t = ST if op == "sari" else VT
            sh = "<<" if op == "shli" else ">>"
            E(R(f"({t})({i[0]}) {sh} {n}"))
        elif op == "rotli":
            n = int(ca[0], 16)
            E(R(f"(({VT})({i[0]}) << {n}) | (({VT})({i[0]}) >> ({bits - n} & {bits - 1}))") if n else f"  {o[0]} = {i[0]};")
        elif op == "shlv":
            # TCTI's shlv gadget is USHL (signed per-lane count, negative =
            # logical right shift); its shrv/rotlv/rotrv expansions rely on that
            E(f"  {o[0]} = aot_ushl{bits}({i[0]}, {i[1]});")
        elif op in ("shrv", "sarv"):
            t = ST if op == "sarv" else VT
            sh = ">>"
            E(R(f"({t})({i[0]}) {sh} (({t})(({VT})({i[1]}) & {bits - 1}))"))
        elif op in ("shls", "shrs", "sars"):
            t = ST if op == "sars" else VT
            sh = "<<" if op == "shls" else ">>"
            E(R(f"({t})({i[0]}) {sh} (({t}){{0}} + (({i[1]}) & {bits - 1}))"))
        elif op == "cmp":
            c = int(ca[0], 16)
            m = {8: ("==", VT), 9: ("!=", VT), 2: ("<", ST), 3: (">=", ST), 6: (">", ST),
                 7: ("<=", ST), 10: ("<", VT), 11: (">=", VT), 14: (">", VT), 15: ("<=", VT)}
            if c not in m:
                raise Unsupported(f"vec cond {c}")
            rel, t = m[c]
            E(R(f"({t})({i[0]}) {rel} ({t})({i[1]})"))
        elif op == "bitsel":
            E(R(f"(({i[0]}) & ({i[1]})) | (~({i[0]}) & ({i[2]}))"))
        elif op in ("ssadd", "sssub", "usadd", "ussub"):
            t = ST if op[0] == "s" else VT
            fn = "__builtin_elementwise_add_sat" if op.endswith("add") else "__builtin_elementwise_sub_sat"
            E(R(f"{fn}(({t})({i[0]}), ({t})({i[1]}))"))
        elif op in ("smin", "smax", "umin", "umax"):
            t = ST if op[0] == "s" else VT
            fn = "__builtin_elementwise_min" if op.endswith("min") else "__builtin_elementwise_max"
            E(R(f"{fn}(({t})({i[0]}), ({t})({i[1]}))"))
        elif op == "aa64_sshl":
            E(f"  {o[0]} = aot_sshl{bits}({i[0]}, {i[1]});")
        elif op == "aa64_sli":
            n = int(ca[0], 16)
            E(R(f"(({VT})({i[1]}) << {n}) | (({VT})({i[0]}) & ({VT}){{0}} + ({lane})((1ull << {n}) - 1))"))
        else:
            raise Unsupported("vec op " + op)

    def gen_tb(self, tb):
        h = tb["hdr"]
        if h["ok"] != "1":
            raise Unsupported("capture:" + h["why"])
        temps = tb["temps"]
        nexits, icount, npool = int(h["nexits"]), int(h["icount"]), int(h["npool"])
        RA, POOL = nexits, nexits + icount
        decls = {}

        def tinfo(t):
            d = temps[t]
            return d

        def width(t):
            d = temps[t]
            k = d[0]
            if k in ("E", "B", "G", "K", "P"):
                ty = int(d[1])
                if ty == 0:
                    return 32
                if ty == 1:
                    return 64
                if ty in (3, 4):
                    return "v"
                raise Unsupported("vector temp type %d" % ty)
            if k == "F":
                return 64
            raise Unsupported("temp kind " + k)

        def ex(t):
            d = temps[t]
            k = d[0]
            w = width(t)
            if w == "v":
                if k in ("E", "B"):
                    decls[t] = "aot_v128"
                    return f"v{t}"
                if k == "K":
                    v = int(d[3], 16)
                    return f"((aot_v128){{0x{v:x}ull, 0x{v:x}ull}})"
                raise Unsupported("vector temp kind " + k)
            if k in ("E", "B"):
                decls[t] = U[w]
                return f"v{t}"
            if k == "G":
                return f"G{w}({d[4]})"
            if k == "F":
                return "((uint64_t)(uintptr_t)env)"
            if k == "K":
                v = int(d[3], 16)
                return f"0x{v & 0xffffffff:x}u" if w == 32 else f"0x{v:x}ull"
            if k == "P":
                return f"((uint64_t)R[{POOL + int(d[2])}])"
            raise Unsupported("temp")

        def base(t):
            return "env" if temps[t][0] == "F" else f"PTR({ex(t)})"

        def cond(c, w, a, b):
            c = int(c, 16) if isinstance(c, str) else c
            u, s = U[w], S[w]
            m = {0: "0", 1: "1",
                 8: f"({u})({a}) == ({u})({b})", 9: f"({u})({a}) != ({u})({b})",
                 12: f"(({u})({a}) & ({u})({b})) == 0", 13: f"(({u})({a}) & ({u})({b})) != 0",
                 2: f"({s})({a}) < ({s})({b})", 3: f"({s})({a}) >= ({s})({b})",
                 6: f"({s})({a}) > ({s})({b})", 7: f"({s})({a}) <= ({s})({b})",
                 10: f"({u})({a}) < ({u})({b})", 11: f"({u})({a}) >= ({u})({b})",
                 14: f"({u})({a}) > ({u})({b})", 15: f"({u})({a}) <= ({u})({b})"}
            if c not in m:
                raise Unsupported(f"cond {c}")
            return m[c]

        out = []
        E = out.append
        exitn = 0
        cur = -1
        BIN = {"add": "{a} + {b}", "sub": "{a} - {b}", "mul": "{a} * {b}", "and": "{a} & {b}",
               "or": "{a} | {b}", "xor": "{a} ^ {b}", "andc": "{a} & ~{b}", "orc": "{a} | ~{b}",
               "eqv": "~({a} ^ {b})", "nand": "~({a} & {b})", "nor": "~({a} | {b})",
               "shl": "{a} << ({b} & {m})", "shr": "{a} >> ({b} & {m})",
               "sar": "({u})(({s}){a} >> ({b} & {m}))",
               "rotl": "__builtin_rotateleft{w}({a}, {b} & {m})",
               "rotr": "__builtin_rotateright{w}({a}, {b} & {m})",
               "div": "aot_div{w}({a}, {b})", "divu": "aot_divu{w}({a}, {b})",
               "rem": "aot_rem{w}({a}, {b})", "remu": "aot_remu{w}({a}, {b})"}
        UN = {"not": "~{a}", "neg": "-{a}", "mov": "{a}",
              "ext8s": "({u})({s})(int8_t)({a})", "ext8u": "({u})(uint8_t)({a})",
              "ext16s": "({u})({s})(int16_t)({a})", "ext16u": "({u})(uint16_t)({a})",
              "ext32s": "(uint64_t)(int64_t)(int32_t)({a})", "ext32u": "(uint64_t)(uint32_t)({a})",
              "ctpop": "__builtin_popcount{bi}({a})"}
        LD = {"ld8u": ("uint8_t", 0), "ld8s": ("int8_t", 1), "ld16u": ("uint16_t", 0),
              "ld16s": ("int16_t", 1), "ld32u": ("uint32_t", 0), "ld32s": ("int32_t", 1),
              "ld": (None, 0)}
        ST = {"st8": "uint8_t", "st16": "uint16_t", "st32": "uint32_t", "st": None}

        for (name, p1, p2, no, ni, ta, ca) in tb["ops"]:
            if name.endswith("_vec"):
                self.gen_vec(name[:-4], p1, p2, no, ni, ta, ca, ex, base, E)
                continue
            if name in ("ext_i32_i64", "extu_i32_i64", "extrl_i64_i32", "extrh_i64_i32"):
                op, w = name, 64
            elif "_" in name and name.rsplit("_", 1)[1] in ("i32", "i64"):
                op, sfx = name.rsplit("_", 1)
                w = 32 if sfx == "i32" else 64
            else:
                op, w = name, 64
            o = [ex(t) for t in ta[:no]]
            i = [ex(t) for t in ta[no:]]
            if w == 32 and op not in ("call", "qemu_ld", "qemu_st") and op not in LD and op not in ST:
                # _i32 ops see the low half of a 64-bit temp (mov_i32 from i64)
                i = [f"(uint32_t)({x})" if width(t) == 64 else x for x, t in zip(i, ta[no:])]
            fmt = dict(u=U[w], s=S[w], m=SH[w], w=w, bi=BI[w])
            if op == "insn_start":
                cur += 1
                E(f"  /* insn {cur} @+{ca[0] if ca else '?'} */")
                continue
            ra = f"R[{RA + max(cur, 0)}]"
            if op == "discard":
                continue
            if op in BIN:
                E(f"  {o[0]} = ({U[w]})({BIN[op].format(a=i[0], b=i[1], **fmt)});")
            elif op in UN:
                E(f"  {o[0]} = ({U[w]})({UN[op].format(a=i[0], **fmt)});")
            elif name == "ext_i32_i64":
                E(f"  {o[0]} = (uint64_t)(int64_t)(int32_t)({i[0]});")
            elif name == "extu_i32_i64":
                E(f"  {o[0]} = (uint64_t)(uint32_t)({i[0]});")
            elif name == "extrl_i64_i32":
                E(f"  {o[0]} = (uint32_t)({i[0]});")
            elif name == "extrh_i64_i32":
                E(f"  {o[0]} = (uint32_t)(({i[0]}) >> 32);")
            elif op in ("clz", "ctz"):
                fn = "__builtin_clz" if op == "clz" else "__builtin_ctz"
                E(f"  {o[0]} = ({U[w]})(({i[0]}) ? ({U[w]}){fn}{BI[w]}({i[0]}) : ({i[1]}));")
            elif op in ("bswap16", "bswap32", "bswap64"):
                bits = int(op[5:])
                flags = int(ca[0], 16) if ca else 0
                if bits == 64:
                    E(f"  {o[0]} = __builtin_bswap64({i[0]});")
                elif bits == w:
                    E(f"  {o[0]} = __builtin_bswap32({i[0]});")
                else:
                    sb = {16: "int16_t", 32: "int32_t"}[bits]
                    ub = {16: "uint16_t", 32: "uint32_t"}[bits]
                    if flags & 4:
                        E(f"  {o[0]} = ({U[w]})({S[w]})({sb})__builtin_bswap{bits}(({ub})({i[0]}));")
                    else:
                        E(f"  {o[0]} = ({U[w]})__builtin_bswap{bits}(({ub})({i[0]}));")
            elif op in ("setcond", "negsetcond"):
                c = cond(ca[0], w, i[0], i[1])
                v = "1" if op == "setcond" else f"({U[w]})-1"
                E(f"  {o[0]} = ({c}) ? {v} : 0;")
            elif op == "movcond":
                c = cond(ca[0], w, i[0], i[1])
                E(f"  {o[0]} = ({c}) ? ({i[2]}) : ({i[3]});")
            elif op == "brcond":
                c = cond(ca[0], w, i[0], i[1])
                E(f"  if ({c}) goto {ca[1]};")
            elif op == "br":
                E(f"  goto {ca[0]};")
            elif op == "set_label":
                E(f" {ca[0]}:;")
            elif op == "deposit":
                pos, ln = int(ca[0], 16), int(ca[1], 16)
                E(f"  {{ uint64_t m_ = aot_mask({ln}) << {pos}; {o[0]} = ({U[w]})((({i[0]}) & ~m_) | "
                  f"(((uint64_t)({i[1]}) << {pos}) & m_)); }}")
            elif op == "extract":
                pos, ln = int(ca[0], 16), int(ca[1], 16)
                E(f"  {o[0]} = ({U[w]})((({U[w]})({i[0]}) >> {pos}) & aot_mask({ln}));")
            elif op == "sextract":
                pos, ln = int(ca[0], 16), int(ca[1], 16)
                E(f"  {o[0]} = ({U[w]})((({S[w]})(({U[w]})({i[0]}) << ({w} - {pos} - {ln}))) >> ({w} - {ln}));")
            elif op == "extract2":
                pos = int(ca[0], 16)
                E(f"  {o[0]} = ({U[w]})((({U[w]})({i[0]}) >> {pos}) | (({U[w]})({i[1]}) << ({w} - {pos})));")
            elif op in ("add2", "sub2"):
                if w == 32:
                    sign = "+" if op == "add2" else "-"
                    E(f"  {{ uint64_t r_ = ((uint64_t)({i[1]}) << 32 | ({i[0]})) {sign} ((uint64_t)({i[3]}) << 32 | ({i[2]}));"
                      f" {o[0]} = (uint32_t)r_; {o[1]} = (uint32_t)(r_ >> 32); }}")
                else:
                    sign = "+" if op == "add2" else "-"
                    E(f"  {{ __uint128_t r_ = ((__uint128_t)({i[1]}) << 64 | ({i[0]})) {sign} ((__uint128_t)({i[3]}) << 64 | ({i[2]}));"
                      f" {o[0]} = (uint64_t)r_; {o[1]} = (uint64_t)(r_ >> 64); }}")
            elif op in ("mulu2", "muls2"):
                if w == 32:
                    ty = "uint64_t" if op == "mulu2" else "int64_t"
                    ct = "uint32_t" if op == "mulu2" else "int32_t"
                    E(f"  {{ uint64_t r_ = (uint64_t)(({ty})({ct})({i[0]}) * ({ty})({ct})({i[1]}));"
                      f" {o[0]} = (uint32_t)r_; {o[1]} = (uint32_t)(r_ >> 32); }}")
                else:
                    ty = "__uint128_t" if op == "mulu2" else "__int128_t"
                    ct = "uint64_t" if op == "mulu2" else "int64_t"
                    E(f"  {{ __uint128_t r_ = (__uint128_t)(({ty})({ct})({i[0]}) * ({ty})({ct})({i[1]}));"
                      f" {o[0]} = (uint64_t)r_; {o[1]} = (uint64_t)(r_ >> 64); }}")
            elif op in ("muluh", "mulsh"):
                if w == 32:
                    ty, ct = ("uint64_t", "uint32_t") if op == "muluh" else ("int64_t", "int32_t")
                    E(f"  {o[0]} = (uint32_t)((uint64_t)(({ty})({ct})({i[0]}) * ({ty})({ct})({i[1]})) >> 32);")
                else:
                    ty, ct = ("__uint128_t", "uint64_t") if op == "muluh" else ("__int128_t", "int64_t")
                    E(f"  {o[0]} = (uint64_t)((__uint128_t)(({ty})({ct})({i[0]}) * ({ty})({ct})({i[1]})) >> 64);")
            elif op in LD:
                ct, sgn = LD[op]
                if ct is None:
                    ct = U[w]
                off = s64(ca[0])
                if sgn:
                    E(f"  {o[0]} = ({U[w]})({S[w]})*({ct} *)({base(ta[no])} + {off});")
                else:
                    E(f"  {o[0]} = ({U[w]})*({ct} *)({base(ta[no])} + {off});")
            elif op in ST:
                ct = ST[op] or U[w]
                off = s64(ca[0])
                E(f"  *({ct} *)({base(ta[1])} + {off}) = ({ct})({i[0]});")
            elif op in ("qemu_ld", "qemu_st"):
                oi, ofs, sz, sgn, bsw, ab, mmu = ca
                sz, sgn, bsw, ab = int(sz), int(sgn), int(bsw), int(ab)
                if sz > 3:
                    raise Unsupported("ldst128")
                if op == "qemu_ld":
                    k = self.helper(LDST_SYMS[sz], None) if False else sz
                    sym = LDST_SYMS[sz]
                    val = "r_"
                    E(f"  {{ uint64_t a_ = {i[0]}; uint64_t r_; uintptr_t h_ = aot_tlb(env, a_, {ofs}, 0, {sz}, {ab});")
                    E(f"    if (likely(h_)) {{ r_ = aot_ldh(h_, {sz});{' r_ = aot_bswap(r_, %d);' % sz if bsw else ''} }}")
                    E(f"    else {{ RT_SLOW_BEGIN(); r_ = ((uint64_t (*)(void *, uint64_t, uint32_t, uintptr_t))"
                      f"H({k}, {sym}))(env, a_, 0x{oi}, {ra}); RT_SLOW_END(aot_tlb(env, a_, {ofs}, 0, {sz}, {ab}) != 0); }}")
                    if sgn:
                        val = f"aot_sext(r_, {sz})"
                    E(f"    {o[0]} = ({U[w]}){val}; }}")
                else:
                    k = 4 + sz
                    sym = LDST_SYMS[k]
                    vt = "uint64_t" if sz == 3 else "uint32_t"
                    E(f"  {{ uint64_t a_ = {i[1]}; uint64_t v_ = {i[0]}; uintptr_t h_ = aot_tlb(env, a_, {ofs}, 1, {sz}, {ab});")
                    E(f"    if (likely(h_)) {{ RT_JOURNAL(h_, {1 << sz}); aot_sth(h_, {sz}, {'aot_bswap(v_, %d)' % sz if bsw else 'v_'}); }}")
                    E(f"    else {{ RT_SLOW_BEGIN(); ((void (*)(void *, uint64_t, {vt}, uint32_t, uintptr_t))"
                      f"H({k}, {sym}))(env, a_, ({vt})v_, 0x{oi}, {ra}); RT_SLOW_END(0); }} }}")
            elif op == "call" and ca[0] in ("ld_i128", "st_i128") and self.inline_i128(
                    ca[0], no, ni, ta, temps, ex, E, f"R[{RA + max(cur, 0)}]"):
                pass
            elif op == "call":
                hname, tm, flags, off = ca[0], int(ca[1], 16), ca[2], int(ca[3])
                sym = "helper_" + hname
                if self.syms is not None:
                    if sym not in self.syms:
                        raise Unsupported("unknown helper " + sym)
                    off = self.syms[sym] - self.syms["aot_anchor"]
                k = self.helper(sym, off)
                ret = tm & 7
                codes = []
                n = 1
                while (tm >> (3 * n)) & 7:
                    codes.append((tm >> (3 * n)) & 7)
                    n += 1
                ctype = {2: "uint32_t", 3: "uint32_t", 4: "uint64_t", 5: "uint64_t",
                         6: "uint64_t", 7: "__uint128_t"}
                args, at, ti = [], [], no
                for c in codes:
                    at.append(ctype[c])
                    if c == 7:
                        # i128 = two call slots in (low, high) order (tmp_subindex
                        # 0, 1 on a little-endian host); after copy propagation
                        # they may be any i64 temps.
                        lo, hi = ta[ti], ta[ti + 1]
                        args.append(f"((__uint128_t)({ex(hi)}) << 64 | ({ex(lo)}))")
                        ti += 2
                    else:
                        args.append(ex(ta[ti]))
                        ti += 1
                if ti != no + ni:
                    raise Unsupported(f"call arity {hname}")
                rt = "void" if ret == 0 else ctype[ret]
                proto = f"{rt} (*)({', '.join(at) if at else 'void'})"
                callx = f"(({proto})H({k}, {sym}))({', '.join(args)})"
                if self.gen_pt(hname, ret, rt, no, codes, args, ta, temps, ex, width, E, ra, callx):
                    continue
                if UNSAFE_HELPER.search(hname):
                    E("  RT_UNSAFE();")
                E(f"  *ra = {ra};")
                if ret == 0:
                    if no:
                        raise Unsupported("void call with outputs")
                    E(f"  {callx};")
                elif ret == 7:
                    lo, hi = ta[0], ta[1]
                    E(f"  {{ __uint128_t r_ = {callx}; {ex(lo)} = (uint64_t)r_; {ex(hi)} = (uint64_t)(r_ >> 64); }}")
                else:
                    if no != 1:
                        raise Unsupported("call outputs")
                    E(f"  {o[0]} = ({U[width(ta[0])]}){callx};")
            elif op == "goto_tb":
                E(f"  AOT_GOTO_TB({exitn});")
                exitn += 1
            elif op == "exit_tb":
                if p2 == 1:
                    # lookup_and_goto_ptr exit (TCTI marks it, see tcg-op.c)
                    E(f"  AOT_GOTO_PTR({exitn});")
                else:
                    E(f"  return R[{exitn}];")
                exitn += 1
            elif op == "mb":
                bar = int(ca[0], 16) & 0xf
                ins = "dmb ishst" if bar == 8 else ("dmb ishld" if bar in (1, 4, 5) else "dmb ish")
                E(f'  __asm__ __volatile__("{ins}" ::: "memory");')
            else:
                raise Unsupported("op " + name)
        if exitn != nexits:
            raise Unsupported("exit count")
        fn = "k" + h["key"]
        body = [f"uintptr_t AOT_FN({fn})(void *env_, const uintptr_t *R, uintptr_t *ra)", "{",
                "  char *env = (char *)env_;"]
        bytype = collections.defaultdict(list)
        for t, ty in sorted(decls.items()):
            bytype[ty].append(f"v{t}")
        for ty, vs in bytype.items():
            for j in range(0, len(vs), 16):
                body.append(f"  {ty} {', '.join(vs[j:j + 16])};")
        body += out
        body += ["  __builtin_unreachable();", "}", ""]
        return fn, "\n".join(body)


def write_if_changed(path, text):
    try:
        with open(path) as f:
            if f.read() == text:
                return
    except OSError:
        pass
    with open(path, "w") as f:
        f.write(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--out", required=True)
    ap.add_argument("--per-file", type=int, default=400)
    ap.add_argument("--max", type=int, default=0)
    ap.add_argument("--prof", help="tbprof.tsv: order/limit by execution count")
    ap.add_argument("--qemu", help="bind helper addresses to this QEMU binary (nm)")
    ap.add_argument("--layout-sig", help="override the layout signature (hex)")
    ap.add_argument("--no-inline-i128", action="store_true")
    ap.add_argument("--cc", default="clang", help="compiler command for build.ninja")
    ap.add_argument("--cflags", default="", help="extra compile flags (target, sysroot)")
    ap.add_argument("--ldflags", default="", help="extra link flags (target, sysroot, install name)")
    ap.add_argument("--no-passthrough", action="store_true",
                    help="plain helper calls only (no same-ISA passthrough)")
    ap.add_argument("--pt-fpsr", action="store_true",
                    help="passthrough rounding FP ops with Inexact clear via the host FPSR")
    ap.add_argument("--pt-stats", action="store_true",
                    help="count passthrough hits/fallbacks (printed at exit if AOT_PT_STATS is set)")
    a = ap.parse_args()
    layout, tbs = parse(a.capture)
    if a.layout_sig:
        layout["sig"] = a.layout_sig
    syms = None
    if a.qemu:
        import subprocess
        syms = {}
        for line in subprocess.run(["nm", a.qemu], capture_output=True, text=True).stdout.splitlines():
            p = line.split()
            if len(p) == 3 and p[1] in "tT":
                syms[p[2][1:] if p[2].startswith("_") else p[2]] = int(p[0], 16)
        anchor = syms["aot_anchor"]
        layout["ldst"] = ",".join(str(syms[x] - anchor) for x in LDST_SYMS)
    if a.prof:
        rank = {}
        with open(a.prof) as f:
            for line in f:
                p = line.split("\t")
                if len(p) == 8:
                    rank[p[0]] = int(p[7])
        tbs.sort(key=lambda t: -rank.get(t["hdr"]["bkey"], 0))
    os.makedirs(a.out, exist_ok=True)
    # TLB table offset per mmu_idx (16-byte CPUTLBDescFast), from the ldst ops
    tlb_base = None
    ld128_off = {}
    for tb in tbs:
        for (name, p1, p2, no, ni, ta, ca) in tb["ops"]:
            if name.startswith("qemu_ld") or name.startswith("qemu_st"):
                tlb_base = int(ca[1]) - 16 * int(ca[6])
            elif name == "call" and ca[0] in ("ld_i128", "st_i128"):
                ld128_off[ca[0][:2]] = int(ca[3])
        if tlb_base is not None and len(ld128_off) == 2:
            break
    if syms is not None:
        for kk in ("ld", "st"):
            ld128_off[kk] = syms[f"helper_{kk}_i128"] - syms["aot_anchor"]
    if a.no_inline_i128:
        tlb_base = None
    g = Gen(layout, syms, tlb_base, ld128_off, passthrough=not a.no_passthrough)
    good = []
    why = collections.Counter()
    seen = set()
    for tb in tbs:
        key = tb["hdr"]["key"]
        if key in seen:
            continue
        seen.add(key)
        if a.max and len(good) >= a.max:
            break
        try:
            fn, code = g.gen_tb(tb)
            good.append((tb, fn, code))
        except Unsupported as e:
            why[str(e).split(":")[0] if str(e).startswith("capture") else str(e)] += 1
        except (KeyError, IndexError, ValueError) as e:
            why["parse:" + type(e).__name__] += 1
    files = []
    for j in range(0, len(good), a.per_file):
        name = f"aot_gen_{j // a.per_file:03d}.c"
        files.append(name)
        text = ['#include "aot_rt.h"\n\n']
        for tb, fn, code in good[j:j + a.per_file]:
            text.append(f"/* pc={tb['hdr']['pc']} size={tb['hdr']['size']} icount={tb['hdr']['icount']} */\n")
            text.append(code)
        write_if_changed(os.path.join(a.out, name), "".join(text))
    # table
    ents = sorted(good, key=lambda x: int(x[0]["hdr"]["key"], 16))
    with open(os.path.join(a.out, "aot_table.c"), "w") as f:
        f.write('#include "aot_rt.h"\n')
        f.write("typedef struct { uint64_t key, fp; aot_fn_t fn, vfn; uint32_t nexits, icount, npool, flags; } AotEntry;\n")
        f.write("typedef struct { uint32_t magic, abi, page_bits, nentries; uint64_t layout; const AotEntry *entries;\n"
                "  uint32_t nhelpers, nrt; const int64_t *helper_offs; void **helper_ptrs; void **rt_ptrs; } AotTable;\n")
        nh = len(g.helpers)
        f.write(f"void *aot_H[{nh}] __attribute__((visibility(\"hidden\")));\n")
        f.write("void *aot_RT[6] __attribute__((visibility(\"hidden\")));\n")
        f.write(f"static const int64_t helper_offs[{nh}] = {{\n")
        for (sym, off), k in g.helpers.items():
            f.write(f"  {off}, /* {k} {sym} */\n")
        f.write("};\n")
        for tb, fn, code in ents:
            f.write(f"uintptr_t aot_f_{fn}(void *, const uintptr_t *, uintptr_t *);\n")
            f.write(f"#ifdef AOT_WITH_VERIFY\nuintptr_t aot_v_{fn}(void *, const uintptr_t *, uintptr_t *);\n#endif\n")
        f.write("static const AotEntry entries[] = {\n")
        for tb, fn, code in ents:
            h = tb["hdr"]
            f.write(f"  {{ 0x{h['key']}ull, 0x{h['fp']}ull, aot_f_{fn}, "
                    f"\n#ifdef AOT_WITH_VERIFY\n aot_v_{fn},\n#else\n 0,\n#endif\n"
                    f"  {h['nexits']}, {h['icount']}, {h['npool']}, 0 }},\n")
        f.write("};\n")
        # passthrough runtime switch (aot_rt.h rule 1) and optional counters;
        # nothing of it with --no-passthrough, which generates exactly the
        # pre-passthrough output
        if g.passthrough:
            f.write("#include <stdio.h>\n#include <stdlib.h>\n"
                    "int aot_pt_on __attribute__((visibility(\"hidden\")));\n"
                    "__attribute__((constructor)) static void aot_pt_init(void)\n{\n"
                    "  const char *e = getenv(\"QEMU_AOT_PT_FP\");\n"
                    "  aot_pt_on = !(e && *e == '0');\n}\n")
        if a.pt_stats and g.passthrough:
            npt = max(1, len(g.pt_ids))
            f.write(f"uint64_t aot_pt_cnt[{npt}][2] __attribute__((visibility(\"hidden\")));\n")
            f.write(f"static const char *const aot_pt_names[{npt}] = {{\n")
            for hn in g.pt_ids:
                f.write(f'  "{hn}",\n')
            f.write("};\n")
            f.write("__attribute__((destructor)) static void aot_pt_fini(void)\n{\n"
                    "  if (!getenv(\"AOT_PT_STATS\")) return;\n"
                    f"  for (int i = 0; i < {len(g.pt_ids)}; i++) {{\n"
                    "    if (aot_pt_cnt[i][0] | aot_pt_cnt[i][1])\n"
                    "      fprintf(stderr, \"aot-pt %-28s inline %12llu fallback %12llu\\n\", aot_pt_names[i],\n"
                    "              (unsigned long long)aot_pt_cnt[i][0], (unsigned long long)aot_pt_cnt[i][1]);\n"
                    "  }\n}\n")
        f.write("__attribute__((visibility(\"default\"))) const AotTable aot_table = {\n")
        f.write(f"  0x31544f41u, 1, {layout['page_bits']}, {len(ents)}, 0x{layout['sig']}ull, entries,\n")
        f.write(f"  {nh}, 6, helper_offs, aot_H, aot_RT\n}};\n")
    # ninja
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(a.out, "build.ninja"), "w") as f:
        # -mcrc: CRC32 instructions (not in the iOS arm64 baseline, apple-a7);
        # AES/SHA-256 are.  -ffp-contract=off: FP passthrough relies on each C
        # FP operation being one IEEE operation (aot_rt.h).
        ptdef = (" -DAOT_PT_FPSR" if a.pt_fpsr else "") + (" -DAOT_PT_STATS" if a.pt_stats else "")
        ptflags = " -ffp-contract=off -mcrc" if g.passthrough else ""
        f.write(f"cflags = -O2 -fno-strict-aliasing -fwrapv{ptflags} -fPIC -fvisibility=hidden -w "
                f"-I{here} -DAOT_PAGE_BITS={layout['page_bits']}{ptdef if g.passthrough else ''} {a.cflags}\n")
        f.write(f"rule cc\n  command = {a.cc} $cflags $extra -c $in -o $out\n")
        f.write(f"rule link\n  command = {a.cc} -dynamiclib {a.cflags} {a.ldflags} -o $out $in\n")
        objs, vobjs = [], []
        for name in files:
            o = name[:-2] + ".o"
            vo = name[:-2] + ".v.o"
            f.write(f"build {o}: cc {name}\n")
            f.write(f"build {vo}: cc {name}\n  extra = -DAOT_VERIFY\n")
            objs.append(o)
            vobjs.append(vo)
        f.write("build aot_table.o: cc aot_table.c\n")
        f.write("build aot_table.v.o: cc aot_table.c\n  extra = -DAOT_WITH_VERIFY\n")
        f.write(f"build libaot.dylib: link {' '.join(objs)} aot_table.o\n")
        f.write(f"build libaot-verify.dylib: link {' '.join(objs + vobjs)} aot_table.v.o\n")
        f.write("default libaot.dylib\n")
    print(f"tbs in capture: {len(tbs)}  generated: {len(good)}  helpers: {len(g.helpers)}  files: {len(files)}")
    if g.passthrough:
        print(f"passthrough: {sum(g.pt_static.values())} call sites of {len(g.pt_static)} helpers inlined"
              f"{' (FPSR variant)' if a.pt_fpsr else ''}")
    for k, v in why.most_common(30):
        print(f"  skipped {v:7d}  {k}")


if __name__ == "__main__":
    main()
