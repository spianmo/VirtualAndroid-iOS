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

| milestone | TCG JIT | TCTI | TCTI + AOT | AOT speedup vs TCTI |
|---|---|---|---|---|
| kernel `Run /init` | 1.80 (0.95) | 7.18 (3.74) | 3.60 (2.28) | 2.0x |
| init second stage | 6.68 (6.03) | 16.94 (13.55) | 9.50 (8.10) | 1.8x |
| start `zygote` | 69.6 (68.9) | 365.8 (362.3) | 171.7 (170.2) | 2.13x |
| start `surfaceflinger` | 71.1 (70.3) | 383.9 (380.5) | 179.6 (178.2) | 2.14x |

References: HVF reaches zygote at about 10 s guest time, and the official
emulator (HVF) reaches `boot_completed` in 26 s. Against the TCG JIT, TCTI is
5.2x slower and TCTI+AOT is 2.4x slower.

Run data: `.logs/aot-results/{jit,tcti,tcti-aot,verify}.json`; serial logs
are kept next to them.

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
- `goto_tb` reads the TB's own jump slot. If that slot is chained to a TB
  that also has native code (header == `gadget_aot_enter`), the function
  tail-calls it with `musttail`. Hot loops therefore stay native without
  returning to the dispatcher, and every TB still runs its own icount/exit
  check first. Otherwise it returns the slot's stream address and TCTI
  follows it.
- Build flags: `-O2 -fno-strict-aliasing -fwrapv` (TCG freely aliases env
  with different widths).

The cache from the capture boot:
- 100,176 TBs (92k distinct bkeys, the top 100k of prof1 that were
  translated during a TCTI boot), all supported (0 skipped)
- 70 helpers
- 167 MB of C
- `libaot.dylib` 42.8 MB, of which 33.1 MB is `__text` (about 330 B per TB)
  and 4.8 MB is the table
- compiled in 30 s wall on 6 cores

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
4. Size budget: about 330 B of native code plus 48 B of table per TB. A
   100k-TB cache is about 38 MB of text; 200k TBs (99.96 % of profiled
   executions) would be about 75 MB. 20k TBs cover 90 % for about 7.5 MB.
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

## Limits

- On a hit, the speedup per TB is bounded by the remaining non-native work:
  - softmmu TLB lookups
  - helpers: FP/NEON-heavy code is mostly helper calls, which are already
    native C in TCTI
  - leaving to the dispatcher at every `exit_tb(0)`: TCTI sets
    `CF_NO_GOTO_PTR`, so every indirect branch and return goes through
    `cpu_exec` and `tb_lookup`
  - cold TBs that still run as gadgets

  The overall gain is 2.1x; the JIT is still 2.4x faster.
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

1. Native indirect branches: an inline `lookup_tb_ptr` with a direct tail
   call to the target TB's native function when it has one, instead of
   `exit_tb(0)` + `cpu_exec`. This is likely the largest remaining win:
   returns and indirect calls are a large share of exits.
2. Superblocks: merge chains of hot TBs (profiled edges) into one C function
   so clang can keep guest registers in host registers across TBs.
   Correctness on an exit check or fault stays per-insn through `R[ra]`.
3. Specialize hot helpers by inlining them: flag computations, `vfp_*`,
   crypto. That means compiling the generated code together with QEMU's
   helper sources, which requires a static link.
4. iOS integration: `-DAOT_STATIC`, cross-compile, link into the QEMU
   framework (engine/qemu-ios), and measure on a device.
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
  (`QEMU_AOT_VERIFY=4096`, `-smp 4`; reaches surfaceflinger at 215 s wall,
  `.logs/aot-results/stats-verify.json`):

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
