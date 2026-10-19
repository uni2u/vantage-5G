#!/usr/bin/env python3
"""
counter_verdict.py — judge the same iperf3 spec by Vantage's own byte counters.

Why (X3, leader decision B): the cap is "L2 bytes the UE sends/receives,
TCP ACKs included". iperf3 goodput excludes L2/L3/L4 headers and the ACKs of
the opposite-direction session, so it reads a few % under the cap even when the
policer is exact. The BPF counters measure exactly what the cap governs:
  UL row -> rx_bytes of that UE (bytes the XDP policer admitted)
  DL row -> tx_bytes of that UE (bytes the tc pacer scheduled)

Inputs: spec.csv (as iperf_verdict.py) and two `vantage-5G stats` snapshots,
each preceded by a line "t=<epoch seconds>" (run-tests.sh writes them at
t0+skip and near the end of the iperf3 run).

Usage: counter_verdict.py spec.csv stats_t1.txt stats_t2.txt [--tol 0.10]
Exit 1 if any capped row is outside tolerance. cap 0 rows are reported only.
"""
import argparse
import csv
import sys


def read_snap(path):
    t = None
    rows = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("t="):
                t = float(line[2:])
                continue
            p = line.split()
            if len(p) == 7 and p[1].isdigit():
                rows[p[0]] = [int(x) for x in p[1:]]
    if t is None:
        raise SystemExit("{}: no t= line".format(path))
    return t, rows


ap = argparse.ArgumentParser()
ap.add_argument("spec")
ap.add_argument("snap1")
ap.add_argument("snap2")
ap.add_argument("--tol", type=float, default=0.10)
a = ap.parse_args()

t1, s1 = read_snap(a.snap1)
t2, s2 = read_snap(a.snap2)
dt = t2 - t1
fails = 0
print("window {:.2f} s (counter deltas between the two snapshots)".format(dt))
print("{:<12} {:<15} {:<3} {:>8} {:>10} {:>7}  {}".format(
    "label", "ue_ip", "dir", "cap", "counter", "err%", "verdict"))
with open(a.spec) as f:
    for r in csv.reader(l for l in f if l.strip() and not l.lstrip().startswith("#")):
        if r[0].strip() == "label":
            continue
        label, ue, d, cap = r[0].strip(), r[1].strip(), r[2].strip().upper(), float(r[3])
        col = 0 if d == "UL" else 3          # rx_bytes / tx_bytes
        name = "rx_bytes" if d == "UL" else "tx_bytes"
        if ue not in s1 or ue not in s2 or dt <= 0:
            print("{:<12} {:<15} {:<3} {:>8.1f} {:>10} {:>7}  FAIL (no counters for UE)".format(
                label, ue, d, cap, "-", "-"))
            fails += 1
            continue
        mbps = (s2[ue][col] - s1[ue][col]) * 8 / dt / 1e6
        if cap == 0:
            print("{:<12} {:<15} {:<3} {:>8.1f} {:>10.3f} {:>7}  INFO ({})".format(
                label, ue, d, cap, mbps, "-", name))
            continue
        e = (mbps - cap) / cap
        ok = abs(e) <= a.tol
        fails += 0 if ok else 1
        note = "" if ok else (" — over cap: policer/pacer admits too much" if e > 0
                              else " — under cap: offered load below cap or bottleneck elsewhere")
        print("{:<12} {:<15} {:<3} {:>8.1f} {:>10.3f} {:>+7.1f}  {} ({}){}".format(
            label, ue, d, cap, mbps, e * 100, "PASS" if ok else "FAIL", name, note))
print("\nfail={}  (tol=±{:.0f}%, L2 bytes incl. ACKs)".format(fails, a.tol * 100))
sys.exit(1 if fails else 0)
