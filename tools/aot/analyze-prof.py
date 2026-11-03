#!/usr/bin/env python3
"""Analyze tbprof.tsv profiles (see tbprof.c).

  analyze-prof.py PROF.tsv [--train OTHER.tsv] [--hot-out hot.txt --hot-n N]
                  [--json out.json]

Reports execution concentration (top-N TBs), distinct TBs / guest bytes,
kernel vs user split and, with --train, how much of PROF's execution would be
covered by an AOT cache built from OTHER's hottest TBs (cross-boot stability).
"""
import argparse, json, sys

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
    ap.add_argument("--json")
    a = ap.parse_args()
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
    out = json.dumps(res, indent=1)
    print(out)
    if a.json:
        with open(a.json, "w") as f:
            f.write(out)


if __name__ == "__main__":
    main()
