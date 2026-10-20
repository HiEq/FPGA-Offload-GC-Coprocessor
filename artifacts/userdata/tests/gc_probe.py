#!/usr/bin/env python3
# ============================================================
# gc_probe.py - time a real CPython full collection
#
#   usage: python3 gc_probe.py <n> [fanout]
#   output: "<ms> <freed>"   (freed = gc.collect()'s return, i.e. unreachable
#                             objects it collected -- NOT a mark count, so the
#                             C side must not compare it with MARKED)
#
# Builds n live container objects with the requested fan-out (default 2; test_main
# passes the same avg_refs it gives the hardware graph), then times gc.collect()
# three times and reports the best.
#
# This is the CPython baseline used by test_main. It measures what CPython's
# collector actually costs on this board (whole interpreter heap, mark+sweep),
# which is a different measurement from py_bfs.py (a Python-level BFS over
# /dev/mem) -- keep the two apart when quoting numbers.
# ============================================================
import gc
import sys
import time


def build(n, fanout=2):
    objs = [{'refs': []} for _ in range(n)]
    for i in range(n):
        r = objs[i]['refs']
        for k in range(fanout):
            r.append(objs[(i * 7 + k * 13 + 1) % n])
    return objs


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
    fanout = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    keep = build(n, fanout)
    gc.collect()                      # settle whatever the build left behind

    best = None
    freed = 0
    for _ in range(3):
        t0 = time.perf_counter()
        freed = gc.collect()
        dt = (time.perf_counter() - t0) * 1000.0
        best = dt if best is None else min(best, dt)

    sys.stdout.write("%.3f %d\n" % (best, freed))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
