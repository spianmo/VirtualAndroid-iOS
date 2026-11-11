# AOT translation cache for TCTI (M5)

Stock iOS apps cannot JIT, so on a real iPhone QEMU has to use UTM's TCTI
backend. TCTI turns each TCG op into the address of a precompiled "gadget" and
threads through them. This document covers the ahead-of-time cache that
replaces the hottest TBs' gadget streams with native functions. Those
functions are generated offline from QEMU's own optimized TCG ops, compiled by
clang, and signed as part of the app.

Everything here was measured on macOS (Apple Silicon, same ISA as the
iPhone) with the AOSP API 33 r02 arm64 image, `-M virt -smp 4 -m 2048`,
`-accel tcg,thread=multi`, `-cpu cortex-a76`, using a fresh userdata image for
every run (`tools/run-macos.sh --fresh --tcg`).

## Results

Times in seconds: host wall clock since launch, with the guest kernel
timestamp from `serial.log` in parentheses. The board does not have goldfish
pipe yet, so `boot_completed` cannot be reached; surfaceflinger is the last
milestone that every run reaches.

Each cell is run 1 / run 2.

| milestone | TCG JIT | TCTI | TCTI+AOT v1 | + native goto_ptr | + inline LDP/STP (final) |
|---|---|---|---|---|---|
| kernel `Run /init` | 1.80 | 7.18 / 6.66 | 3.60 / 4.38 | 2.83 / 3.07 | 2.81 / 2.82 |
| init second stage | 6.68 | 16.94 / 16.16 | 9.50 / 10.53 | 8.48 / 8.46 | 7.68 / 7.94 |
| start `zygote` | 69.6 | 365.8 / 380.3 | 171.7 / 179.7 | 131.8 / 141.9 | **109.5 / 110.8** |
| start `surfaceflinger` | 71.1 | 383.9 / 398.4 | 179.6 / 203.5 | 139.3 / 152.6 | **115.7 / 117.4** |
| speedup vs TCTI (zygote, mean) | 5.4x | 1.0x | 2.1x | 2.7x | **3.4x** |

Columns:
- TCG JIT: guest kernel time 0.95 / 6.03 / 68.9 / 70.3 s for the four
  milestones.
- TCTI: run 1 is the unmodified worktree; run 2 is the AOT-capable binary
  with no table loaded. Its numbers match run 1, so the hooks cost nothing.
- TCTI+AOT v1: per-TB native functions and goto_tb native chaining.

References: HVF reaches zygote at about 10 s guest time, and the official
emulator (HVF) reaches `boot_completed` in 26 s. TCTI is 5.4x slower than the
TCG JIT; final TCTI+AOT is 1.6x slower than the JIT.

Run data and serial logs are in `.logs/aot-results/`. The final rows are
`tcti-aot-i128{,-2}.json`.

Where time goes. With macOS `sample`, 15 s around zygote preload,
"busy" means vCPU threads not idle in WFI. These are per-function shares of
busy vCPU samples:

| configuration | i128 ld/st helpers | next-TB lookup (`helper_lookup_tb_ptr`, `cpu_get_tb_cpu_state`, qht) | native code |
|---|---|---|---|
| AOT v1 | ~30 % | | |
| goto_ptr build | | ~20 % | ~17 % (the rest is softmmu slow path, GIC, locks) |

The i128 helpers handle every LDP/STP of X registers, so every prologue and
epilogue. The goto_ptr and i128 columns of the results table are the two
fixes that followed from this profile.

## Profile of a boot (step 2)

Recorded with `tools/aot/tbprof.c`, a TCG plugin with inline per-vCPU
counters. It runs on the JIT build because plugin-instrumented TBs do not
match AOT fingerprints. Two independent fresh boots were profiled: `prof1`
runs until surfaceflinger plus 120 s, `prof2` stops at surfaceflinger.
Analysis is done by `tools/aot/analyze-prof.py`.

| | prof1 | prof2 |
|---|---|---|
| distinct TBs (content keys) | 608,290 | 433,380 |
| guest code bytes covered by TBs | 12.8 MB | 8.7 MB |
| TB executions | 1.53e10 | 1.04e10 |
| guest instructions | 7.55e10 | 5.06e10 |
| avg insns / TB exec | 4.93 | 4.88 |
| TBs for 50 / 90 / 99 % of executions | 1,406 / 19,325 / 69,250 | 1,351 / 17,028 / 56,764 |
| top 10k / 50k / 100k TBs cover | 81.1 / 97.8 / 99.6 % | |
| kernel share of execs (insns) | 28.6 % (31.4 %) | 17.4 % (20.3 %) |
| user, mmap area (libs, oat, JIT cache) | 68.8 % | 79.4 % |
| user, PIE executables | 2.5 % | 3.1 % |

Execution is heavily concentrated: 20k TBs, about 400 KB of guest code, cover
90 % of executed TBs.

The keys are also stable across boots (KASLR and ASLR do not matter because
the key is content-based). Of prof2's executions, 100.0 % belong to TBs whose
content key also appears in prof1. In the other direction, 98.7 % of prof1's
executions are covered by prof2's keys. The missing 1.3 % comes almost
entirely from the extra 120 s in prof1: 1.0 % user-mmap, 0.25 % executables,
0.09 % kernel. That 1.3 % is an upper bound on code that is generated at
runtime or not reproducible (ART JIT and similar) within this window. During
boot up to surfaceflinger, ART JIT code is negligible. It will grow once apps
run, which is why the guest-side mitigation below matters.

## Design

### Where it hooks in (engine/qemu-aot, branch `aot`)

- `accel/tcg/translate-all.c`: after `translate_code`, calls
  `aot_tb_translated()` with the guest bytes (`host_pc`, `tb->size`). TBs that
  span two pages or come from MMIO are not cacheable.
- `tcg/tcg.c`: after `tcg_optimize` and liveness, `aot_tb_ops()` walks the
  final op list. It does two things:
  - capture (`QEMU_AOT_CAPTURE`): dump the ops in a self-describing text form.
  - lookup: find the content key in the loaded table, then recompute the op
    fingerprint and compare it.
- TCTI backend (`tcg/aarch64-tcti`): on a hit, `tcg_out_tb_start` emits a
  2-word header `[gadget_aot_enter, AotRec*]` in front of the normal TCTI
  stream. `tcg_out_exit_tb` and `tcg_out_goto_tb` record the stream offset of
  every exit. The new gadget `aot_enter` calls `rec->call(env, rec->w, &ra)`
  and continues at the stream address that the function returns.
- `tb_gen_code`: `aot_tb_finalize()` writes the `AotRec` after the search
  data. It holds three things, all found by the native code in one
  `const uintptr_t *R`:
  - exit addresses
  - per-insn unwind return addresses
  - pooled constants
- Everything else in QEMU is unchanged:
  - The TB still owns a complete TCTI stream, so the slow paths stay as they
    are: `tb_add_jump` patches the same slots, invalidation works as before,
    and `cpu_restore_state` unwinds through the same search data.
  - On a miss, TCTI runs as before.

### Cache key and safety

```
bkey = H(guest insn bytes of the TB, page offset of pc, byte size)   // also used by tbprof
key  = H(bkey, tb->flags, tb->cs_base, tb->cflags & ~CF_INVALID)
fp   = H(canonical optimized op list)
```

Because `CF_PCREL` is set, the generated code depends only on these inputs.
The fingerprint guards against everything else: a different QEMU build,
different CPU features or a backend option. It is computed over:
- opcodes, op params and constant args
- temp kinds, types and indices
- global env offsets
- `MemOpIdx` plus the TLB table offset of every guest access
- helper name, typemask and flags
- label ids, `goto_tb`/`exit_tb` indices
- `insn_start` data

Constants that may be host pointers (2^32 ≤ v < 2^48) are excluded from the
fingerprint and passed through `R[]`. If the fingerprint, exit count or icount
differs, the native function is not used: the counter is `fp_mismatch`, and it
was 0 in every run.

The table also checks the ABI and layout when it loads:
- magic number and ABI version
- `sizeof(CPUArchState)`, the TLB entry layout and page bits
- the helper binding: offsets of the 8 slow-path `helper_*_mmu` relative to
  `aot_anchor`

If any check fails, the table is rejected as a whole. That happened (by
design) every time I rebuilt QEMU. `tcg2c.py --qemu BIN` rebinds the cache by
running `nm`; only `aot_table.c` changes and relinking takes 2.6 s.

### Self-modifying code and invalidation

QEMU's page-level SMC tracking is untouched. A guest store to a page that
holds TBs invalidates them, exactly as before. The native code runs only as
part of an existing, valid TB. A retranslation recomputes the key from the
new bytes, so a modified TB simply misses, or hits another entry whose bytes
match. The native store fast path compares against `addr_write` including the
`TLB_NOTDIRTY`/MMIO/watchpoint flag bits, the same way as the JIT backend.
Stores to code pages therefore always go through `helper_st*_mmu`, which
performs the invalidation.

### Generated code (tools/aot/tcg2c.py, aot_rt.h)

Each TB becomes one C function,
`uintptr_t f(void *env, const uintptr_t *R, uintptr_t *ra)`:

- TCG globals become loads and stores at fixed env offsets, so they are
  always coherent across helper calls.
- EBB and TB temps become C locals (scalar or 128-bit vector types). Labels
  become `goto`.
- All integer ops are covered, including add2/mulu2/extract/deposit and the
  bswap flags. Vector ops cover what the TCTI backend accepts
  (ld/st/dup/arith/logic/shifts/cmp/bitsel/sat/minmax/`aa64_sshl`/`aa64_sli`).
  Div/rem use AArch64 sdiv/udiv semantics, matching TCTI.
- `qemu_ld/st` use an inline softmmu TLB fast path (same comparison as the
  aarch64 JIT backend, alignment included). On a miss they call the same
  `helper_ld*/st*_mmu` with the per-insn return address, so faults unwind to
  the right guest pc through the TB's search data.
- `call` calls the helper through its real C prototype, rebuilt from the
  typemask, with i128 passed as `__uint128_t`. Before every call it sets
  `*ra = R[ra_index]`, which is what TCTI's `GETPC()` reads.
- `exit_tb` returns the stream address of the TB's own exit gadget, so TCTI
  produces the exact same `tb|idx` value.
- `exit_tb` from `lookup_and_goto_ptr`: TCTI runs every TB with
  `CF_NO_GOTO_PTR`, so every indirect branch and return used to go back to
  `cpu_exec`. `tcg_gen_lookup_and_goto_ptr` now marks that `exit_tb`
  (`TCGOP_FLAGS = 1`, ignored by the TCTI backend, part of the fingerprint).
  At such sites the native code calls `aot_rt_goto_ptr`, which does the same
  as JIT `goto_ptr`:
  - It calls `helper_lookup_tb_ptr`.
  - If the next TB is native, it tail-calls it.
  - Otherwise it continues in that TB's TCTI stream.
  - On a miss it takes the old exit.

  The marker is not applied to single-step, one-insn or `CF_NO_GOTO_TB` TBs.
  Effect: zygote 176 → 137 s.
- `helper_ld_i128` / `helper_st_i128` (LDP/STP of X registers,
  `MO_ATOM_IFALIGN_PAIR`) are inlined. The fast path does a 16-byte TLB
  check (page-crossing checked) and then two 8-byte host accesses, which are
  single-copy atomic when aligned; that is all `IFALIGN_PAIR` requires. The
  slow path calls the same helper. Effect: 137 → 110 s.
- `goto_tb` reads the TB's own jump slot. If that slot is chained to a TB
  that also has native code (header == `gadget_aot_enter`), the function
  tail-calls it with `musttail`. Hot loops therefore stay native without
  returning to the dispatcher, and every TB still runs its own icount/exit
  check first. Otherwise it returns the slot's stream address and TCTI
  follows it.
- Build flags: `-O2 -fno-strict-aliasing -fwrapv` (TCG freely aliases env
  with different widths).

The final cache, from one TCTI capture boot:
- 98,534 TBs (the top 100k bkeys of prof1 that were translated during the
  capture boot), all supported (0 skipped)
- 70 helpers
- `libaot.dylib` 47.6 MB: 38.1 MB `__text` (about 390 B per TB) plus a
  4.7 MB table
- compiled in about 30 s wall on 6 cores per variant

Measured against prof1 and prof2, those bkeys cover 96.7 % and 97.3 % of all
TB executions (99.3 % / 99.6 % of kernel executions).

### Verification mode

`QEMU_AOT_LIB=libaot-verify.dylib QEMU_AOT_VERIFY=N` checks each AOT TB on its
first 4 executions and on every Nth one after that. A check runs these steps:
1. Snapshot env.
2. Run the journaled native variant (`-DAOT_VERIFY`: every fast-path store
   records the old bytes).
3. Roll back memory and env.
4. Run the original TCTI stream of the same TB with its `goto_tb` slots
   temporarily unchained.
5. Compare the exit value, the whole `CPUArchState` (78 KB) and the stored
   bytes. The TCTI result is the one that is kept.

Some executions are not compared because they cannot be replayed, and are
counted as `v_unsafe`:
- helpers with external side effects
- slow-path or MMIO accesses
- TBs that store while `CF_PARALLEL` is set

Fields that other threads write asynchronously are never written back and
are not compared: `irq_line_state` and the generic-timer `ctl`/`cval`.

Two things look like failures but are races between vCPUs, and are
classified separately:
- `v_flaky`: a store-free mismatch where a re-run of the native code from the
  same snapshot agrees with TCTI (spin loops over lock words).
- `v_chainrace`: another vCPU re-chained the slot during the reference run.

Results are in "Correctness" below.

Debugging aids:
- `QEMU_AOT_KEYRANGE=lo-hi` and `QEMU_AOT_PC=kernel|user` restrict the table.
- `tools/aot/bisect.py` bisects a broken boot down to one TB. This found the
  only miscompile so far (i128 helper argument halves swapped, now fixed).

### Producing the cache for a release

1. Profile on macOS with the JIT build and `tbprof` over several scripted
   sessions (boot, launcher, common apps) and merge the TSVs. This tells us
   which bkeys are hot.
2. Capture with the exact release QEMU configuration. The op list depends on
   the backend, so for iOS this means the TCTI build: run
   `QEMU_AOT_CAPTURE=ops.txt QEMU_AOT_HOT=hot.txt` on the macOS TCTI build of
   the same source.
3. Run `tcg2c.py ops.txt --qemu <binary> --out gen/`, compile with clang for
   `arm64-apple-ios` and link the objects statically into the app framework.
   - Production builds should use `-DAOT_STATIC` (direct helper calls, no
     `aot_H` binding table) and drop the verify variant.
   - The table is checked against the same layout signature when the app
     starts.
4. Size budget: about 390 B of native code plus 48 B of table per TB
   (unwind info comes on top). A 100k-TB cache is about 48 MB on disk; 200k
   TBs (99.96 % of profiled executions) would be about 95 MB. 20k TBs cover
   90 % for about 10 MB.
   - iOS has no limit on signed code size beyond the app's install size.
   - The hottest-first order lets us cut at whatever size we choose.
   - The cache is tied to the QEMU build (fingerprints, layout), so it has
     to be regenerated with every engine change. This is fully automated and
     takes about 7 min of TCTI capture plus 1 min of compilation.
5. Guest-side mitigation: make ART compile everything AOT
   (`pm compile -m speed -a`, or `dalvik.vm.dex2oat-filter=speed`, and
   `dalvik.vm.usejit=false` where acceptable, at first boot or baked into a
   prepared userdata/snapshot). JIT-generated code can never be in an offline
   cache. With full AOT, the oat files have deterministic content per image
   and their TBs become cacheable like any other user code.

### Same-ISA passthrough

Guest and host are both AArch64, so many helper calls of a hot TB have an
architectural result that is one host instruction. tcg2c.py (default on,
`--no-passthrough` for A/B, `engine/scripts/ios/build_aot.sh
--no-passthrough` or `AOT_PASSTHROUGH=0`) emits those calls as
`aot_pt_<helper>()` from `aot_rt.h`; the table is `PASSTHROUGH` in tcg2c.py
(158 helpers). The exactness rules are in the comment block of `aot_rt.h`;
in short:

- Integer, crypto and CRC (`muluh/mulsh_i64`, `udiv64/sdiv64`, `rbit*`,
  `neon_narrow/widen_u*`, `neon_clz_u16`, AES/SHA-256, `crc32c_64`, integer
  pairwise and `cnt`/`rbit` bytes) always produce the helper's result.
  `crc32_64` (zlib) falls back when the accumulator has bits above 31.
- FP (`vfp_*` arithmetic, fma, sqrt, min/max, compares, conversions,
  `rint*`, the AdvSIMD `gvec_f*`/`gvec_vcvt_*` forms; never half precision)
  runs inline only when it can prove a bit-identical result and
  `float_status`: host FPCR == 0 (read on every call), `float_status` bytes
  3..17 equal to FPCR.FZ = FIZ = DN = AH = 0, RNE where the op rounds, no
  NaN or denormal input, and for rounding arithmetic Inexact already set
  and a result that cannot be tiny or infinite (QEMU's own hardfloat rule).
  Conversions compute Inexact exactly. Everything else calls the helper with
  the same arguments, so NaN propagation, default NaN, FZ/FIZ/AH and all
  other flags still come from softfloat. `QEMU_AOT_PT_FP=0` turns the FP
  part off at run time.
- gvec helpers: the descriptor must be a TB constant with maxsz 16 (so SVE
  vector lengths keep the helper); the tail is cleared like `clear_tail()`
  and every input is loaded before vd is written (aliasing).
- `--pt-fpsr` also inlines rounding FP ops while Inexact is clear: one asm
  block clears the host FPSR, runs the instruction and reads FPSR back; only
  IXC is accepted. Off by default.
- The build adds `-mcrc` (CRC32 is not in the arm64 iOS baseline; the app's
  iOS 17 deployment target implies A12 or later, which has it) and
  `-ffp-contract=off`. `--no-passthrough` output is byte-identical to the
  generator before the passthrough.

Tests (all under tools/aot/tests):
- `pt-unit/run.sh`: links `pt_unit.c` against the real helper objects of
  `engine/build-macos-aot-tcti` and compares helper and passthrough on
  random and edge-case inputs under default/AH behaviours, all rounding
  modes, FZ, FIZ, DN, random flags, host FPCR != 0 and aliased gvec
  registers (all 18 bytes of `float_status`, every vector byte; a declining
  passthrough must not change anything). Default and `-DAOT_PT_FPSR`
  builds. `pt_unit bench` gives rough per-call times. `pt-proto-check.py`
  (run first) compiles every table entry against its DEF_HELPER prototype.
- `fp-passthrough/run.sh [--cpu max]`: bare-metal guest program, every
  passed-through instruction over special values and FPCR settings (also
  FEAT_AFP AH/FIZ/NEP with `--cpu max`); JIT, TCTI and TCTI+AOT (passthrough,
  production, `--pt-fpsr`, `--no-passthrough`, verify variant with
  `QEMU_AOT_VERIFY=1`) must print identical output.
- `pt-bench/run.sh`: hot guest loops timed with the guest counter.

Results (2026-11-04, M2 Max, shared host): pt-unit 158 helpers x 2M random
cases (two seeds; `-DAOT_PT_FPSR` build 1M), 0 failures (ten deliberately injected bugs in
`aot_rt.h`, nine are caught, the tenth is the conservative `crc32_64`
accumulator check). fp-passthrough on cortex-a76 and max: all outputs
identical to the JIT, verify variant 51.0 M / 40.9 M executions compared,
0 mismatches. pt-bench (ns per loop iteration, best of 3, -smp 1):

| loop | JIT | TCTI | AOT no passthrough | AOT passthrough | speedup |
|---|---|---|---|---|---|
| FP scalar (fmadd, fmul, fadd, fdiv) | 22.4 | 70.4 | 19.0 | 16.5 | 1.15x |
| FP vector (fmla, fmul, fadd 2d, fmla by element) | 82.1 | 139.1 | 83.2 | 22.0 | 3.8x |
| FP conversions (fcvtzs, scvtf, frintm, fcmp) | 57.3 | 159.8 | 43.1 | 14.7 | 2.9x |
| AES/SHA-256 | 27.7 | 57.3 | 27.7 | 6.6 | 4.2x |
| CRC32/udiv/umulh/rbit | 41.4 | 63.8 | 43.3 | 5.5 | 7.9x |

`--pt-fpsr` is within 2 % of the default build on these loops (they keep
Inexact set). In the ranchu capture/profile (prof-r1) the passed-through
helpers are 2.4e9 of the 4.6e9 dynamic helper calls that were still calls
(`ld/st_i128` are already inline), mostly AES/SHA-256, `muluh_i64`,
`crc32c_64` and `udiv64`; FP is 0.2e9.

### 128-bit atomics under TCTI (stop-the-world)

UTM's TCTI tree disabled the 128-bit cmpxchg helper ("FIXME: this doesn't
work in TCTI" in `host/include/generic/host/atomic128-cas.h.inc` and
`accel/tcg/cputlb.c`), so `HAVE_CMPXCHG128` was 0. Then every guest CASP and
every LDXP/STXP pair in a `CF_PARALLEL` TB is translated to
`helper_exit_atomic`: the vCPU leaves the TB, `cpu_exec_step_atomic` stops
all vCPUs (`start_exclusive`) and runs that one instruction alone. The kernel
uses CASP for SLUB's `cmpxchg_double` (every kmalloc/kfree fast path), and
bionic/ART use 128-bit atomics in user space.

Measured with macOS `sample` on the simulator TCTI+AOT slice (prebaked
userdata, kpti=0), share of the vCPU threads' busy time spent in
`cpu_exec_step_atomic` plus waiting in `cpu_exec_start`/`cpu_exec_end` for
another vCPU's exclusive section:

| phase | busy | stop-the-world share of busy |
|---|---|---|
| idle home screen | 13 % | 11 % |
| Settings scrolling | 42 % | 27 % |
| steady UI workload | 37 % | 44 % |
| cold app start | 80 % | 51 % |

Why it was disabled: `helper_atomic_cmpxchgo_le(env, addr, cmpv, newv, oi)`
needs seven argument slots (two i128), and `tcg_target_call_iarg_regs` had
only R0-R5. The seventh went to TCTI's temp buffer (R15 as call stack), which
the C helper, called by the `call` gadget with the host's x0-x7, never sees.
The fix (engine/qemu-ios, engine/qemu-aot and engine/qemu, uncommitted; kept
for release: the device slice ios-arm64 a003aa34bab9 and its va_aot
ca8200466819 in `engine/build-ios/xcframeworks` carry it):

- `tcg/aarch64-tcti/tcg-target.c.inc`: R0-R7 as argument registers. TCG
  registers R0-R13 are host x0-x13 and the `call` gadget branches with them
  untouched, so this is AAPCS64. Darwin passes an i128 in any two consecutive
  registers, which is what `TCG_CALL_ARG_NORMAL` (already set) produces.
- The two `!defined(CONFIG_TCG_THREADED_INTERPRETER)` exclusions removed, so
  `HAVE_CMPXCHG128` is 1 and the `DATA_SIZE 16` atomic helpers are built.

Only the TBs that contain such an instruction change their op list (the
fingerprint differs, so an old table simply misses them): 45 bkeys of the
250k-TB capture, 0.17 % of profiled TB executions.

`tools/aot/tests/atomic128/run.sh` races 4 threads on one 16-byte pair (CASP,
LDAXP/STLXP, CASP readers against one writer, plus 64-bit CAS/LDXR for
reference) under `-smp 4` MTTCG, as `/init` of an initramfs on the image's
kernel, and checks count, invariant and atomicity. All pass on JIT, old TCTI,
new TCTI and new TCTI with an AOT cache of the test. ns per successful update,
macOS M2 Max:

| test | JIT | TCTI before | TCTI after | TCTI after + AOT |
|---|---|---|---|---|
| CASP, 4 writers | 28 | 10,688 | 195 | 191 |
| LDAXP/STLXP, 4 writers | 17 | 5,195 | 141 | 165 |
| CASP, 1 writer + 3 CASP readers | 16 | 48,631 | 35 | 175 |
| 64-bit CAS (unchanged) | 76 | 71 | 27 | 50 |

The TCTI differential fuzzer (`tcg/aarch64-tcti/tests/run-fuzz.sh`, which
emits CASP among its atomics) passes 40/40 seeds against the JIT, and
`run-tests.sh` passes. The verify variant on this test reports mismatches
only in kernel TBs without any 128-bit cmpxchg (spinning loads of lock words,
the known class in "Correctness").

Cache: the 45 bkeys were recaptured (top-up capture with `QEMU_AOT_HOT` = those
bkeys during a boot of the fixed simulator slice, 53 TBs) and merged in front of
cap-r2-final with `analyze-prof.py --merge-out ... --merge-max 250000`:
`.logs/aot-ios/cap-r2-a128-final.txt`, 250,000 TBs, 0 `exit_atomic` calls,
53 `helper_atomic_cmpxchgo_le` calls, coverage of prof-r2 unchanged (99.35 %).
With the r2 cache the fixed binary reports 93 fingerprint mismatches (exactly
those TBs, which then run as gadgets); with the merged cache 0.

Simulator A/B (2026-11-05, iPhone 17 Pro simulator on M2 Max, TCTI + AOT,
prebaked userdata, kpti=0, no va-bluetooth; with the fix: the real
`engine/build-ios` slice and its cap-r2-a128-final cache; without: an isolated
build of the same engine/qemu-ios tree with the fix reverted and a cap-r2-final
cache bound to it; workload.py `--steady-only --steady-rounds 1 --scale 3
--qmp`, i.e. touches from the host; five app cold starts with `am start -W`
2 min after Launcher3 is focused; production AOT settings, i.e. only
`QEMU_AOT_LIB`). Host load average about 17 (Spotlight indexing), the same for
all three runs. Results in `.logs/a128/ab3/`.

| | without fix | with fix (2 runs) |
|---|---|---|
| start `zygote` | 25.8 s | 23.8 / 21.7 s |
| `sys.boot_completed` | 208.4 s | **73.1 / 70.7 s** |
| Launcher3 focused | 307.5 s | **90.0 / 88.4 s** |
| cold start DeskClock / Calendar / Dialer / Settings | 8.4 / 4.3 / 9.3 / 7.8 s | **2.5 / 1.6 / 1.9 / 2.4 s** (both runs within 0.2 s) |
| steady UI: frames drawn / janky | 3123 / 37.1 % | **4056 / 20.1 %, 4194 / 17.1 %** |
| steady workload wall time | 480.6 s | 449.8 / 449.0 s |
| tb_flush during the session | 2 | 1 |

Per step (p50 / p90 frame time, ms, without -> with): Settings app list
28 / 250 -> 21-26 / 36-38, recents 44 / 150 -> 26 / 44-48, notification shade
44 / 69 -> 34-36 / 48-57, app drawer 28 / 109 -> 20-22 / 34-38, Settings search
44 / 150 -> 19-20 / 34. Plain Settings scrolling was already smooth without the
fix (6-9 % janky either way). AOT: 0 fingerprint mismatches in all runs.

An earlier set of runs (`.logs/a128/sim-new`, `sim-old`) had
`QEMU_AOT_STATS` set on both sides. That switches off native chaining between
AOT TBs and the native goto_ptr (`tcg/aot.c`, "stats/verify mode") and adds
timing, so its absolute numbers are about 1.5x slower (boot_completed 109-114 s
with the fix, 274-278 s without); the comparison between the two builds
pointed the same way. Its `sample` profiles gave the stop-the-world share of
active vCPU time: 51.6 % during an app cold start and 17.4 % in the steady
workload without the fix, 2.6-2.7 % and 0.8-0.9 % with it.

Open issue: rare early-boot hang. 2 of 137 simulator boots with the fix hung
at about 5 s guest time (one A/B boot, `.logs/a128/sim-new/run-2/serial-hang.log`,
and one of 30 boots to zygote, `.logs/a128/hang/hz17.serial.log`): soft lockup
of `kworker/0:1` in virtio_console `add_port` -> `__send_control_msg`,
spinning on `virtqueue_get_buf` for the PORT_READY control buffer, right after
init loaded virtio_pci.ko and enabled the PCI devices behind the console; init
itself stops there too and zygote never starts. 0 of about 87 boots without the
fix hung (40 in an interleaved A/B, 20 with 26 extra virtio-serial ports, the
others from earlier sessions), but at this rate that is no evidence either way
(Fisher exact p = 0.37). The 135 boots after the first two hung none: 40
interleaved pairs, 20 stressed pairs (26 extra ports, about 10x the control
messages per boot), 40 plain fixed boots under host load 20, 3 BT validation
boots. Neither the guest code on that path nor QEMU's `control_out` uses 128-bit
atomics, and with `ioeventfd=off` the device handles the kick synchronously in
the kicking vCPU, so the plausible shapes are a lost kick or the device going
`broken` after a `virtio_error` (which would be in qemu.out; neither hang kept
it). `.logs/a128/hang3.sh` now keeps qemu.out, two `x-query-virtio-queue-status`
dumps of every virtio-serial queue and a QEMU sample when a boot hangs.

### Third-party apps (iPhone, 2026-11-05)

Measured on the iPhone 17 Pro Max with Xiaohongshu (`com.xingin.xhs`, 190 MB
APK, 104 MB of native libs, installed from CoolApk inside the guest; userdata
not prebaked, JIT on; guest `simpleperf record -a` and logcat over adb):

- The install-time dexopt never finished: `dumpsys package dexopt` showed
  `status=run-from-apk`. installd kills dex2oat after 570 s
  ("Child process N timed out after 570000ms"; `kLongTimeoutMs`, not scaled
  by `ro.hw_timeout_multiplier`, and dex2oat's own watchdog has the same 9.5
  minutes). Even the `verify` filter of this APK takes 7.7 min (4 threads) on
  an idle guest, and the guest was not idle while the app was installed.
- run-from-apk means every start inflates the dex files out of the APK into
  anonymous memory, verifies every class at runtime (446-1775 "Verification
  of ... took" warnings per start) and finds classes without type lookup
  tables. On the app's main thread `DexFile::FindClassDef` alone was 20 % of
  the samples, the verifier about 15 %, zlib `inflate_fast` 6 %. Cold start
  (`Displayed`): **2m47s**. After `cmd package compile -m verify -f
  com.xingin.xhs` (7.7 min): **46 s**, no runtime verification, no lowmemorykiller
  kill during the start. A following `-m speed-profile` (with the JIT profile)
  hit the 570 s limit again.
- Memory: 2 GB guest, no swap (the image's fstab has no zram entry, so
  `swapon_all` does nothing; the official emulator is the same). The app runs
  four or five processes (about 1.2 GB RSS together, the main one 486 MB while
  run-from-apk); with the ~35 system apps that BOOT_COMPLETED starts,
  lowmemorykiller thrashed and killed the launcher, SystemUI's neighbours and
  finally the app itself in the foreground (oom_score_adj 0), which then started
  again from scratch (10 process starts in an hour). Page reclaim showed up in
  the kernel samples (`page_referenced_one`, `try_to_unmap_one`).
- Once running, most CPU goes to the app's own work: a hot-update download
  and 7-zip decompression (`libun7zip.so` 11 %), its logging thread
  (`libxylog.so` 8-10 %), anti-tamper and tracking SDKs, plus JIT-compiled code
  (8 %). App native libraries and JIT code are never in the offline cache, so
  they run as TCTI gadgets; only the system parts (libart, boot.oat, libc,
  kernel) can hit it, and the r2 capture has no dex2oat at all (prebaked
  userdata boots without compiling).

Consequences: the prebaked initrd profile no longer turns the JIT off or
compiles installs with `speed` (an app installed later would interpret its
code, and a `speed` install of a big app cannot finish within 570 s); the
packs prebaked with the old profile must be prebaked again, because odrefresh
records every `dalvik.vm.*` property and recompiles the boot classpath when one
changes.

Fixes (engine guest setup on the console, `hw/android/guest_time.c`, -machine
options of ranchu):

- `zram-size=MB` (default 1024): once the guest has booted, /dev/block/zram0
  (lz4, set by init.ranchu.rc) becomes swap. With it, the same app session on
  macOS TCTI had one lowmemorykiller kill instead of dozens.
- `dexopt-rescue=on` (default): a background job checks every minute for
  third-party apps whose oat directory has no `base.vdex` (installd gave up)
  while no dex2oat runs. It asks PackageManager for a `verify` compile, takes
  the command line and the environment of the dex2oat that installd starts for
  it (the console shell lacks `BOOTCLASSPATH`/`DEX2OATBOOTCLASSPATH`), kills
  that dex2oat, and runs the same compile itself with `--no-watch-dog`, nice 10,
  on its own fds and in installd's mount namespace (`nsenter`: the console
  shell lives in init's bootstrap namespace, which has no
  `/apex/com.android.art`), then moves `base.vdex`/`base.odex` into place as
  system:all_aNNN 0644 (the directory's SELinux label). PackageManager reports
  `status=verify [reason=cmdline]`; the app starts without runtime verification
  (HVF: Xiaohongshu cold start 570 ms afterwards). Failures are logged with
  dex2oat's last stderr line; a package is given up after three. On the
  simulator TCTI slice the same app started in 29-31 s while run-from-apk and
  in 5.4 s with its verify vdex; the session used 240 MB of the zram swap and
  had no lowmemorykiller kill.
- The prebaked pack was prebaked again with the JIT on (`app/build/ImagePackPrebaked`).
- App workload for the profile and capture: `tools/aot/appload.sh` (install two
  big APKs, two cold starts each with swipes, one `compile -m verify -f`). Its
  JIT profile (prof-r3) showed the r2 cache covering 85.1 % of its TB
  executions. A top-up capture of its 20k hottest missing TBs on the simulator
  TCTI slice (12,840 of them were translated there) merged with the r2 capture
  (`cap-r3-final.txt`, 262,840 TBs, ordered by prof-r2 + prof-r3,
  `prof-r2r3.tsv`) covers 94.45 % of the app workload and 99.38 % of the UI
  workload (r2: 85.1 % / 99.35 %).

## Limits

- Remaining overhead on hit TBs:
  - `helper_lookup_tb_ptr` on every indirect branch (about 20 % of busy
    time)
  - softmmu slow paths
  - helpers: as in the JIT, except the AES/SHA-256/CRC, integer and the
    FP calls that the same-ISA passthrough inlines (see above)
  - cold TBs that still run as gadgets

  The overall gain is 3.4x; the JIT is still 1.6x faster.
- Only TBs seen during profiling are covered. Code that is new to a session
  (apps, JIT) runs at TCTI speed.
- A table is valid for one QEMU binary layout. Different CPU models or
  machine options only cost hit rate (keys and fingerprints differ), never
  correctness.
- The verifier cannot replay stores in `CF_PARALLEL` TBs. Those are covered
  only by the boot milestones and the guest behaving identically. A
  `-smp 1` verification run with an `-smp 1` capture would also compare
  them.
- Not measured yet: an iPhone, UI frame rate, and boot_completed. The last
  one needs the goldfish pipe board.

## Next steps

1. Indirect branches are native already (goto_ptr). Next: a per-site inline
   cache in `R[]`, keyed on pc plus a flags check, before calling
   `helper_lookup_tb_ptr`, to cut the remaining ~20 %. Also return-address
   prediction for RET.
2. Superblocks: merge chains of hot TBs (profiled edges) into one C function
   so clang can keep guest registers in host registers across TBs.
   Correctness on an exit check or fault stays per-insn through `R[ra]`.
3. Specialize hot helpers by inlining them: flag computations, `vfp_*`,
   crypto. The same-ISA passthrough (above) does this for helpers whose
   result is one host instruction; the rest would mean compiling the
   generated code together with QEMU's helper sources (static link).
4. iOS integration: done as a separate `va_aot.framework` loaded through
   `QEMU_AOT_LIB` (see "iOS integration" below); TCTI+AOT reaches
   `boot_completed` in the simulator and on an iPhone. Left: a plain-TCTI
   device run to `boot_completed` for the A/B, and a stricter binding check.
5. A larger profile corpus (launcher, Settings, a few apps) plus the full-AOT
   ART configuration, then pick the cache size by the coverage curve.

## Correctness

- Boot behaviour, TCTI vs TCTI+AOT (`serial.log`):
  - no kernel panic or oops in either
  - the same set of services started, in the same order apart from known
    exec races
  - the same exit statuses apart from `ranchu-setup`, whose status also
    varies between runs of the official emulator (see
    `reference/emulator_fullboot.log`)
- Verification run over the whole boot to surfaceflinger
  (`QEMU_AOT_VERIFY=4096`, `-smp 4`). The final cache is
  `stats-verify3.json`, and it reaches surfaceflinger at 204 s wall. It
  shows 1,353,217 executions compared and 105 mismatches in 11 TBs, all
  loads of concurrently written words, the same classes as listed below.

  The table that follows is the earlier, pre-goto_ptr cache
  (`stats-verify.json`):

  | counter | value |
  |---|---|
  | TBs translated / AOT TBs installed | 488,473 / 98,470 |
  | fingerprint or shape mismatches | 0 / 0 |
  | AOT TB executions | 5.68e9 |
  | executions checked | 1,726,787 |
  | executions compared against TCTI | 1,237,770 (902 of them faulting) |
  | not replayable (side effects, MMIO, parallel stores) | 488,997 |
  | racy, resolved by re-run | 1,258 |
  | chain races | 20 |
  | remaining mismatches | 135, in 14 kernel TBs |

  All 14 remaining TBs read words that other vCPUs write concurrently:
  - 12 are exclusive or acquire loads (memop `0xe24`) of lock or atomic
    words, followed by a barrier; the two runs saw values one increment
    apart.
  - One reads a jiffies-like counter (0xffffafb9 vs 0xffffafba).
  - One reads a bitmap word.

  I inspected the generated C for the two most frequent ones: it is a plain
  `ldaxr` / `eor` / `cbnz`. None of the mismatches is attributable to
  translation.

  Two miscompiles were found and fixed while bringing this up:
  - i128 helper argument halves were swapped. `tools/aot/bisect.py` isolated
    the single TB, a kernel `stp` through `helper_st_i128`.
  - Strict aliasing was not disabled (now `-fno-strict-aliasing`).

  Three verifier bugs were also fixed:
  - Lost async updates of CNTV_CTL.ISTATUS caused an IRQ storm.
  - `exit_tb(0)` exits were misclassified as chain races.
  - A reference run could leave its TB through a slot re-chained by another
    vCPU and nest into a second verification.

## iOS integration (ranchu, 2026-11-04)

The runtime is merged into the iOS engine source (engine/qemu-ios, branch
`ios` at 231f0b92c: master 0e17cd59b + `aot` up to a1a9daff4, including the
TCTI fix 08b6a2cac, plus 55bb17924; merged into engine master as
16d34a09f). 55bb17924 keeps the translation-time counters always on and
prints
`aot: translated N TBs, … table hits, … mismatches, … native` at exit when a
table is loaded. The cache ships as its own framework, `va_aot.framework`,
next to the TCTI QEMU slice it is bound to; the app sets `QEMU_AOT_LIB` to it
under TCTI (`-VAAOT NO` turns it off for A/B runs).

Pipeline (each step reruns after an engine change):

1. Profile on macOS with the JIT build and tbprof, ranchu, fresh userdata,
   then a scripted UI session (`tools/aot/workload.py`: Settings and three of
   its pages, app drawer, notification shade, nine AOSP apps):
   `tools/run-macos.sh --fresh --tcg --machine ranchu … -- -plugin libtbprof.dylib,out=prof.tsv`
   plus `workload.py --serial 127.0.0.1:PORT --quit-monitor RUN/monitor.sock`.
   `analyze-prof.py --hot-out hot.txt --hot-n 200000`.
2. Capture with the simulator TCTI build (same source and configuration as
   the device slice): `SIMCTL_CHILD_QEMU_AOT_CAPTURE=cap.txt
   SIMCTL_CHILD_QEMU_AOT_HOT=hot.txt engine/scripts/ios/run_sim.sh -b tcti --fresh`.
3. `engine/scripts/ios/build_aot.sh -p ios_simulator|ios -c cap.txt --prof prof.tsv`
   (tcg2c.py with the platform's clang, sysroot and target, helpers bound to
   that platform's QEMU binary with nm), then `make_xcframeworks.sh`, which
   adds `va_aot.xcframework` only for TCTI slices whose binary matches
   `qemu-tcti/aot/bound-qemu.sha1`.

Profile (prof-r1: boot to `boot_completed` plus the UI session, JIT, 2.09 M
distinct TBs, 3.6e10 executions): the top 10k / 50k / 100k / 200k TBs cover
74.2 / 93.1 / 97.2 / 99.1 % of executions. App use spreads execution much
more than the boot-only profile of the virt board did (top 10k: 81.1 %).

Bugs found while bringing it up on ranchu (all fixed):
- TCTI `cmp_vec` LT/LE and LTU/LEU picked the wrong instruction
  (08b6a2cac on `aot`): NEON `CMLT #0` / `CMLE #0` were wrong on zero lanes,
  and zygote died in every preload (ICU `MissingResourceException`). The
  differential fuzzer in `tcg/aarch64-tcti/tests` (a1a9daff4, TCTI vs JIT,
  random integer/memory/atomic/NEON streams) found nothing else.
- tcg2c translated `shlv_vec` as a generic left shift. TCTI's `shlv` gadget is
  `USHL` (signed per-lane count) and its `shrv`/`rotlv`/`rotrv` expansions use
  negative counts, so register right shifts came out as left shifts. Under
  TCTI+AOT zygote then hung right after `Using memfd for future sealing`.
  Now `aot_ushl{8,16,32,64}` in `aot_rt.h` (checked against the hardware
  `USHL`/`SSHL` for counts -70..70 on every lane size).
- Not a CPU bug: under TCTI apexd timed out waiting for new
  `/dev/block/loopN` nodes, `com.android.media` stayed inactive and zygote
  preload died with `NoClassDefFoundError` (SystemServiceRegistry). The
  kernel command line now has `loop.max_loop=64` (a50c9f3, run_sim.sh), and
  the initrd sets `ro.hw_timeout_multiplier=5` so the system_server watchdog
  tolerates TCTI speed (b5b73bf).

Final cache: 211,716 TBs from three TCTI captures (kernel to zygote preload;
boot to `boot_completed`; boot plus the UI session), 129 helpers, 97 MB on
the device slice.

Simulator, fresh userdata, host wall clock, iPhone 17 Pro simulator on M2
Max, no other VM running:

| milestone | TCTI | TCTI+AOT |
|---|---|---|
| init second stage | 20.7 s | 9.3 s |
| start `zygote` | 418.9 s | 175.8 s (2.4x) |
| start `surfaceflinger` | 434.4 s | 192.7 s |
| start `bootanim` | 452.9 s | 204.0 s |
| `sys.boot_completed=1` | 1061.0 s | **463.1 s (2.3x)** |
| zygote `BeginPreload` | 7.6 s | 2.8 s |

Both runs: zygote deaths 0, ANRs 0, watchdog kills 0. TCTI+AOT: 2,100,256
TBs translated, 384,855 table hits (18 %), 0 fingerprint or shape
mismatches.

Device (iPhone 17 Pro Max, A19 Pro, iOS 27.2, TCTI+AOT, same slices, fresh
userdata, guest seconds, measured by the device session): Run /init 1.45,
init second stage 6.3, zygote 154.2, surfaceflinger 162.4, bootanim 175.1,
`boot_completed` 433.2; Launcher3 displayed about 2 min later; Settings and
Camera open (`docs/iphone-home-screen.png`). No plain-TCTI run to `boot_completed` on the device yet (an
earlier one with the ICU bug reached zygote at 357 s).

Remaining:
- Only 18 % of translated TBs hit the table after boot; the rest of the time
  is TCTI gadgets. A larger corpus (more apps, longer sessions) and the
  full-AOT ART configuration (step 5 above) are the next levers.
- A cache is only checked against the layout and the 8 slow-path helper
  offsets. A stale `va_aot.framework` left in an app bundle next to a rebuilt
  QEMU (the embed script copies, it never deletes) could call the wrong
  helpers. `make_xcframeworks.sh` pairs by binary hash, but the app should
  also check the binding, for example the full helper offset table or a QEMU
  build id.

## Files

- engine/qemu-aot (branch `aot`):
  - `include/tcg/aot.h`, `tcg/aot.c`
  - hooks in `accel/tcg/translate-all.c`, `tcg/tcg.c`,
    `tcg/aarch64-tcti/tcg-target.c.inc`
  - the `aot_enter` gadget in `tcg/aarch64-tcti/tcti-gadget-gen.py`
- tools/aot:
  - `build-variants.sh`: builds the JIT and TCTI variants
  - `boot-bench.py`: milestone timer
  - `tbprof.c`: profiling plugin
  - `analyze-prof.py`
  - `tcg2c.py`, `aot_rt.h`: generator and runtime header
  - `try-boot.sh`, `bisect.py`
  - `workload.py`: scripted UI session over adb (profile, capture, timing)
  - `tests/`: same-ISA passthrough tests (`pt-unit/`, `pt-proto-check.py`,
    `fp-passthrough/`, `pt-bench/`) and `helper_rank.py` (dynamic helper
    call ranking from a capture plus a tbprof TSV)
- engine/scripts/ios/build_aot.sh: cross-compiles the cache into
  `va_aot.framework` for one platform (iOS integration above)
