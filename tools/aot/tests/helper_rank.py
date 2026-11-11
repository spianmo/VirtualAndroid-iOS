#!/usr/bin/env python3
"""Rank helper calls by dynamic count (docs/AOT.md, "Same-ISA passthrough").

  helper_rank.py CAPTURE.txt PROF.tsv [--top 30] [--json out.json]

dynamic calls of helper h = sum over captured TBs of
    execs(bkey of the TB, from the tbprof TSV) x (static calls of h in the TB)

The profile is keyed by bkey (guest bytes, page offset, size) like tcg2c.py
--prof; when several captured TBs share a bkey (different flags/cflags), their
static counts are averaged so that the bkey's executions are counted once.
"""
import argparse, collections, json, sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("prof")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--json")
    a = ap.parse_args()
    execs = {}
    with open(a.prof) as f:
        for line in f:
            p = line.split("\t")
            if len(p) == 8:
                execs[p[0]] = execs.get(p[0], 0) + int(p[7])
    per_bkey = {}            # bkey -> [ntbs, Counter]
    bkey = None
    cnt = None
    with open(a.capture) as f:
        for line in f:
            if line.startswith("TB "):
                bkey = line.split(" bkey=", 1)[1].split(" ", 1)[0]
                cnt = collections.Counter()
            elif line.startswith("O call "):
                if cnt is not None and line.count("|") == 2:
                    cnt[line.rsplit("|", 1)[1].split()[0]] += 1
            elif line.startswith("END"):
                if bkey is not None:
                    e = per_bkey.setdefault(bkey, [0, collections.Counter()])
                    e[0] += 1
                    e[1].update(cnt)
                bkey = cnt = None
    dyn = collections.Counter()
    static = collections.Counter()
    tbs_with = collections.Counter()
    covered = 0
    for bk, (n, c) in per_bkey.items():
        x = execs.get(bk, 0)
        covered += x
        for h, k in c.items():
            dyn[h] += x * k / n
            static[h] += k
            tbs_with[h] += 1
    tot = sum(dyn.values())
    rows = []
    acc = 0
    for h, d in dyn.most_common():
        acc += d
        rows.append({"helper": h, "dyn_calls": int(d), "share_pct": round(100 * d / tot, 3),
                     "cum_pct": round(100 * acc / tot, 2), "static_calls": static[h],
                     "bkeys": tbs_with[h]})
    res = {"capture": a.capture, "prof": a.prof, "captured_bkeys": len(per_bkey),
           "tb_execs_of_captured_bkeys": covered, "total_dyn_helper_calls": int(tot),
           "helper_calls_per_tb_exec": round(tot / covered, 4) if covered else 0,
           "helpers": rows}
    print(f"captured bkeys {len(per_bkey)}, their TB execs {covered:.3e}, "
          f"dynamic helper calls {tot:.3e} ({res['helper_calls_per_tb_exec']} per TB exec)")
    print(f"{'#':>3} {'helper':28} {'dyn calls':>12} {'share%':>8} {'cum%':>7} {'static':>8}")
    for i, r in enumerate(rows[:a.top], 1):
        print(f"{i:3d} {r['helper']:28} {r['dyn_calls']:12.4g} {r['share_pct']:8.3f} {r['cum_pct']:7.2f} {r['static_calls']:8d}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(res, f, indent=1)


if __name__ == "__main__":
    main()
