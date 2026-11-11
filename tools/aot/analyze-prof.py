#!/usr/bin/env python3
"""Analyze tbprof.tsv profiles (see tbprof.c).

  analyze-prof.py PROF.tsv [--train OTHER.tsv] [--hot-out hot.txt --hot-n N]
                  [--capture CAP.txt[.zst|.gz]]... [--merge-out OUT.txt[.zst]
                  --merge-max N] [--json out.json]

Reports execution concentration (top-N TBs), distinct TBs / guest bytes,
kernel vs user split and, with --train, how much of PROF's execution would be
covered by an AOT cache built from OTHER's hottest TBs (cross-boot stability).

--capture (repeatable) reads op captures (QEMU_AOT_CAPTURE, see tcg2c.py) and
reports how much of PROF's execution they cover: a profile TB (bkey) counts as
covered when a capture holds a translatable record (ok=1) with that bkey.
--merge-out writes one capture for tcg2c.py: the ok=1 records of all
--capture files, the first file winning for a key found in several, without
the records PROF never executed, hottest first (PROF's execution count of the
bkey), at most --merge-max records, under the first file's LAYOUT line. The
file order then already is the cache order, so tcg2c.py --max N keeps the N
hottest without --prof. A key whose fingerprint differs between captures
(other op list, so another QEMU build) is counted as a conflict. Names ending
in .zst or .gz go through zstd / gzip.
"""
import argparse, collections, json, subprocess, sys

COLS = ("bkey", "vaddr", "off", "size", "ninsns", "kernel", "ntrans", "execs")


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) != 8:
                continue
            rows.append((p[0], int(p[1], 16), int(p[3]), int(p[4]), int(p[5]),
                         int(p[6]), int(p[7])))
    return rows  # bkey, vaddr, size, ninsns, kernel, ntrans, execs


def pct(a, b):
    return round(100.0 * a / b, 2) if b else 0.0


def open_text(path, mode="r"):
    """Plain file, or a zstd / gzip stream (by name)."""
    tool = "zstd" if path.endswith(".zst") else "gzip" if path.endswith(".gz") else None
    if tool is None:
        return open(path, mode)
    if mode == "r":
        p = subprocess.Popen([tool, "-dc", path], stdout=subprocess.PIPE, text=True)
    else:
        p = subprocess.Popen([tool, "-q", "-c"], stdin=subprocess.PIPE, text=True,
                             stdout=open(path, "wb"))
    f = p.stdout if mode == "r" else p.stdin

    class Stream:
        def __enter__(self):
            return f

        def __exit__(self, *exc):
            f.close()
            if p.wait() != 0:
                raise OSError(f"{tool} failed on {path}")
    return Stream()


def capture_records(path, want=None):
    """Yield (header dict, record text or None) per TB of an op capture; the
    text is collected only for keys in WANT. A record cut off by a killed run
    (no END) is dropped. The LAYOUT line is yielded as ({"layout": line}, None)."""
    with open_text(path) as f:
        hdr, buf = None, None
        for line in f:
            if line.startswith("TB "):
                hdr = dict(kv.split("=", 1) for kv in line.split()[1:])
                buf = [line] if want is not None and hdr["key"] in want else None
            elif line == "END\n":
                if hdr is not None:
                    if buf is not None:
                        buf.append(line)
                    yield hdr, "".join(buf) if buf is not None else None
                hdr, buf = None, None
            elif line.startswith("LAYOUT "):
                yield {"layout": line}, None
            elif buf is not None:
                buf.append(line)


def capture_coverage(a, rows, tot_e):
    """--capture / --merge-out (see the module docstring)."""
    execs = {r[0]: r[6] for r in rows}
    first = {}                 # key -> (file index, bkey, fp)
    conflicts = 0
    files, layout = [], None
    for fi, path in enumerate(a.capture):
        st = {"path": path, "records": 0, "ok": 0, "new_keys": 0, "not_ok": collections.Counter()}
        for h, _ in capture_records(path):
            if "layout" in h:
                layout = layout or h["layout"]
                st.setdefault("layout", h["layout"].split()[5])   # sig=...
                continue
            st["records"] += 1
            if h["ok"] != "1":
                st["not_ok"][h["why"]] += 1
                continue
            st["ok"] += 1
            k = h["key"]
            if k in first:
                if first[k][2] != h["fp"]:
                    conflicts += 1
                continue
            first[k] = (fi, h["bkey"], h["fp"])
            st["new_keys"] += 1
        st["not_ok"] = dict(st["not_ok"].most_common(8))
        files.append(st)
    cov = {"files": files, "fp_conflicts": conflicts, "unique_ok_keys": len(first)}
    bkeys = collections.Counter(b for _, b, _ in first.values())
    cov["profile_exec_pct_covered"] = pct(sum(execs.get(b, 0) for b in bkeys), tot_e)
    cov["unique_ok_bkeys"] = len(bkeys)
    cov["ok_keys_not_in_profile"] = sum(n for b, n in bkeys.items() if not execs.get(b))
    # profile top N: share of all executions whose TB is in the top N and captured
    top, acc, mi = {}, 0, 0
    marks = [10000, 50000, 100000, 200000, 300000]
    for n, r in enumerate(rows, 1):
        if r[0] in bkeys:
            acc += r[6]
        while mi < len(marks) and n == marks[mi]:
            top[marks[mi]] = pct(acc, tot_e)
            mi += 1
    cov["profile_top_n_captured_exec_pct"] = top
    # cache order: hottest bkey first, then file order
    order = sorted((k for k, (fi, b, fp) in first.items() if execs.get(b)),
                   key=lambda k: -execs[first[k][1]])
    if a.merge_max:
        order = order[:a.merge_max]
    sel = set(order)
    sel_b = set(first[k][1] for k in order)
    by_file = collections.Counter(first[k][0] for k in order)
    cov["merge"] = {"records": len(order),
                    "records_by_file": {a.capture[i]: n for i, n in sorted(by_file.items())},
                    "bkeys": len(sel_b),
                    "profile_exec_pct_covered": pct(sum(execs[b] for b in sel_b), tot_e),
                    "coldest_execs": execs[first[order[-1]][1]] if order else 0}
    if not a.merge_out:
        return cov
    text = {}
    for fi, path in enumerate(a.capture):
        want = set(k for k in sel if first[k][0] == fi)
        if not want:
            continue
        for h, t in capture_records(path, want):
            if t is not None and h["key"] in want and h["ok"] == "1" and h["key"] not in text:
                text[h["key"]] = t
    with open_text(a.merge_out, "w") as f:
        f.write(layout)
        for k in order:
            f.write(text[k])
    cov["merge"]["out"] = a.merge_out
    return cov


def region(vaddr, kernel):
    if kernel:
        return "kernel"
    if vaddr < 0x10000000:
        return "user-low"
    if vaddr < 0x7000000000:
        return "user-exe"        # PIE executables / linker area
    return "user-mmap"           # shared libraries, oat/odex, JIT cache


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prof")
    ap.add_argument("--train")
    ap.add_argument("--hot-out")
    ap.add_argument("--hot-n", type=int, default=20000)
    ap.add_argument("--capture", action="append", default=[])
    ap.add_argument("--merge-out")
    ap.add_argument("--merge-max", type=int, default=0)
    ap.add_argument("--json")
    a = ap.parse_args()
    if a.merge_out and not a.capture:
        ap.error("--merge-out needs --capture")
    rows = load(a.prof)
    rows.sort(key=lambda r: -r[6])
    tot_e = sum(r[6] for r in rows)
    tot_i = sum(r[6] * r[3] for r in rows)
    executed = [r for r in rows if r[6] > 0]
    res = {
        "profile": a.prof,
        "distinct_tbs": len(rows),
        "distinct_tbs_executed": len(executed),
        "guest_code_bytes": sum(r[2] for r in executed),
        "tb_execs": tot_e,
        "guest_insns": tot_i,
        "translations": sum(r[5] for r in rows),
        "retranslated_tbs": sum(1 for r in rows if r[5] > 1),
        "avg_insns_per_tb_exec": round(tot_i / tot_e, 2) if tot_e else 0,
    }
    top = {}
    acc_e = acc_i = 0
    marks = [10, 100, 1000, 5000, 10000, 20000, 50000, 100000, 200000]
    mi = 0
    for n, r in enumerate(rows, 1):
        acc_e += r[6]
        acc_i += r[6] * r[3]
        while mi < len(marks) and n == marks[mi]:
            top[marks[mi]] = {"tb_exec_pct": pct(acc_e, tot_e), "insn_pct": pct(acc_i, tot_i),
                              "bytes": sum(x[2] for x in rows[:n])}
            mi += 1
    res["top"] = top
    for q in (50, 90, 99):
        acc = 0
        for n, r in enumerate(rows, 1):
            acc += r[6]
            if acc >= tot_e * q / 100:
                res[f"tbs_for_{q}pct_execs"] = n
                break
    reg = {}
    for r in rows:
        k = region(r[1], r[4])
        d = reg.setdefault(k, {"distinct": 0, "execs": 0, "insns": 0, "bytes": 0})
        d["distinct"] += 1
        d["execs"] += r[6]
        d["insns"] += r[6] * r[3]
        d["bytes"] += r[2]
    for k, d in reg.items():
        d["exec_pct"] = pct(d["execs"], tot_e)
        d["insn_pct"] = pct(d["insns"], tot_i)
    res["regions"] = reg

    if a.train:
        tr = load(a.train)
        tr.sort(key=lambda r: -r[6])
        allkeys = set(r[0] for r in tr)
        res["cross"] = {"train": a.train,
                        "any_train_key": {"tb_exec_pct": pct(sum(r[6] for r in rows if r[0] in allkeys), tot_e),
                                          "insn_pct": pct(sum(r[6] * r[3] for r in rows if r[0] in allkeys), tot_i)}}
        for n in (1000, 5000, 10000, 20000, 50000, 100000):
            ks = set(r[0] for r in tr[:n])
            e = sum(r[6] for r in rows if r[0] in ks)
            i = sum(r[6] * r[3] for r in rows if r[0] in ks)
            res["cross"][f"top{n}"] = {"tb_exec_pct": pct(e, tot_e), "insn_pct": pct(i, tot_i)}
        # what is not covered at all, by region
        miss = {}
        for r in rows:
            if r[0] not in allkeys:
                k = region(r[1], r[4])
                miss[k] = miss.get(k, 0) + r[6]
        res["cross"]["uncovered_exec_pct_by_region"] = {k: pct(v, tot_e) for k, v in miss.items()}

    if a.hot_out:
        with open(a.hot_out, "w") as f:
            for r in rows[:a.hot_n]:
                f.write(r[0] + "\n")
        res["hot_out"] = {"path": a.hot_out, "n": min(a.hot_n, len(rows))}
    if a.capture:
        res["capture"] = capture_coverage(a, rows, tot_e)
    out = json.dumps(res, indent=1)
    print(out)
    if a.json:
        with open(a.json, "w") as f:
            f.write(out)


if __name__ == "__main__":
    main()
