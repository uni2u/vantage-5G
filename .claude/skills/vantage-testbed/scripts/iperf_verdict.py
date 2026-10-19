#!/usr/bin/env python3
"""
iperf_verdict.py — judge iperf3 -J results against configured Vantage caps.

Spec file (CSV, '#' comments allowed), one row per iperf3 session:
    label,ue_ip,direction,cap_mbps,json_path
    A-UL,10.45.1.23,UL,10,results/a_ul.json
    A-DL,10.45.1.23,DL,20,results/a_dl.json
    B-DL-kill,10.45.1.24,DL,0,results/b_dl.json     # cap 0 = killswitch

json_path is relative to the spec file's directory.

Verdict per session:
  * steady-state Mbps = mean of interval throughput after --skip seconds
    (drops TCP slow start and the policer's initial 250 ms token burst)
  * cap > 0 : PASS if |steady - cap| / cap <= --tol (default 0.10)
  * cap == 0: PASS if steady <= --kill-max Mbps (default 0.1)  [killswitch]
  * CV (stdev/mean of intervals) > --cv-warn flags an unstable rate, which in a
    concurrent run is the first sign of cross-UE interference.

Usage: python3 iperf_verdict.py spec.csv [--skip 5] [--tol 0.10]
Exit 1 if any session FAILs. Python 3.8 compatible.
"""
import argparse
import csv
import json
import os
import statistics
import sys

ap = argparse.ArgumentParser()
ap.add_argument("spec")
ap.add_argument("--skip", type=float, default=5.0, help="seconds to ignore at start")
ap.add_argument("--tol", type=float, default=0.10)
ap.add_argument("--kill-max", type=float, default=0.1, help="Mbps allowed under killswitch")
ap.add_argument("--cv-warn", type=float, default=0.15)
a = ap.parse_args()

base = os.path.dirname(os.path.abspath(a.spec))
rows = []
with open(a.spec) as f:
    for r in csv.reader(line for line in f if line.strip() and not line.lstrip().startswith("#")):
        r = [x.strip() for x in r]
        if r[0] == "label":
            continue
        rows.append(r)


def steady_mbps(doc, skip):
    vals = []
    for iv in doc.get("intervals", []):
        s = iv.get("sum", {})
        if s.get("omitted"):
            continue
        if s.get("start", 0) < skip:
            continue
        vals.append(s.get("bits_per_second", 0.0) / 1e6)
    end = doc.get("end", {})
    total = (end.get("sum_received") or end.get("sum") or {}).get("bits_per_second", 0.0) / 1e6
    return vals, total


fails = 0
print("{:<12} {:<15} {:<3} {:>8} {:>9} {:>9} {:>7} {:>6}  {}".format(
    "label", "ue_ip", "dir", "cap", "steady", "end_avg", "err%", "CV", "verdict"))
for label, ue_ip, direction, cap, path in rows:
    cap = float(cap)
    p = path if os.path.isabs(path) else os.path.join(base, path)
    try:
        with open(p) as f:
            doc = json.load(f)
    except Exception as e:  # missing/garbled result is a FAIL, not a crash
        print("{:<12} {:<15} {:<3} {:>8.1f} {:>9} {:>9} {:>7} {:>6}  FAIL (cannot read {}: {})".format(
            label, ue_ip, direction, cap, "-", "-", "-", "-", path, e))
        fails += 1
        continue
    if "error" in doc and cap == 0:
        # Killswitch drops every packet to the UE, SYN-ACKs included, so a TCP
        # session that cannot even connect is the expected outcome.
        print("{:<12} {:<15} {:<3} {:>8.1f} {:>9} {:>9} {:>7} {:>6}  PASS — killswitch: {}".format(
            label, ue_ip, direction, cap, "0", "-", "-", "-", doc["error"]))
        continue
    if "error" in doc:
        print("{:<12} {:<15} {:<3} {:>8.1f} {:>9} {:>9} {:>7} {:>6}  FAIL (iperf3 error: {})".format(
            label, ue_ip, direction, cap, "-", "-", "-", "-", doc["error"]))
        fails += 1
        continue
    vals, total = steady_mbps(doc, a.skip)
    steady = statistics.mean(vals) if vals else total
    cv = (statistics.pstdev(vals) / steady) if len(vals) > 1 and steady > 0 else 0.0
    notes = []
    if cap == 0:
        ok = steady <= a.kill_max
        err = "-"
        notes.append("killswitch")
    else:
        e = (steady - cap) / cap
        ok = abs(e) <= a.tol
        err = "{:+.1f}".format(e * 100)
        if not ok and e > 0:
            notes.append("over cap: shaping not applied? (wrong iface / no fq root / no policy)")
        elif not ok:
            notes.append("under cap: bottleneck elsewhere (radio, UPF, CPU) or bucket too small")
    if cv > a.cv_warn:
        notes.append("unstable CV>{:.2f}".format(a.cv_warn))
    if not vals:
        notes.append("no intervals after skip; used end summary")
    verdict = "PASS" if ok else "FAIL"
    fails += 0 if ok else 1
    print("{:<12} {:<15} {:<3} {:>8.1f} {:>9.2f} {:>9.2f} {:>7} {:>6.2f}  {}{}".format(
        label, ue_ip, direction, cap, steady, total, err, cv, verdict,
        (" — " + "; ".join(notes)) if notes else ""))

print("\nsessions={} fail={}  (tol=±{:.0f}%, skip={}s)".format(len(rows), fails, a.tol * 100, a.skip))
sys.exit(1 if fails else 0)
