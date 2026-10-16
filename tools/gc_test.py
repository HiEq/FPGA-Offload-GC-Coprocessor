#!/usr/bin/env python3
# ============================================================
# gc_test.py - FOGCCC on-board FPGA GC mark test (pure Python, /dev/mem)
#   usage: python3 gc_test.py [n_objects] [avg_refs]
#
#   Graph layout: object headers @0x0000 (16B each), ref arrays @0x1000
#   Region [0, 3n/4) = LIVE  (refs only inside LIVE)
#   Region [3n/4, n)  = GARBAGE (refs only inside GARBAGE, unreachable from root)
#   Root set = {0}.  Correct result: hardware marks exactly the LIVE objects
#   reachable from object 0, and nothing from the GARBAGE region.
# ============================================================
import mmap, os, struct, time, random, sys

REG_BASE   = 0x43C00000
GRAPH_BASE = 0x1E000000
GRAPH_SIZE = 0x100000          # 1 MiB

R_CTRL, R_OBJ_BASE, R_OBJ_COUNT, R_ROOT_COUNT = 0x00, 0x04, 0x08, 0x0C
R_MARKED, R_CYCLES, R_Q_HEAD, R_Q_TAIL, R_ROOT_LIST = 0x10, 0x14, 0x18, 0x1C, 0x40

CTRL_START, CTRL_CLEAR_Q, CTRL_DONE = 1, 4, (1 << 31)

HDR_BASE = 0x0000
# REF_BASE is computed in main() so the ref arrays start AFTER all object headers
# (header region = n*16 bytes).  Hardcoding 0x1000 breaks for n > 256.

def task(pct, label):
    sys.stdout.write("@@TASK %d %s\n" % (pct, label))
    sys.stdout.flush()

def main():
    n        = int(sys.argv[1]) if len(sys.argv) > 1 else 4096
    avg_refs = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    roots    = [0]

    task(0, "opening /dev/mem")
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=REG_BASE)
    gph  = mmap.mmap(fd, GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=GRAPH_BASE)

    def rr(o):    return struct.unpack_from('<I', regs, o)[0]
    def wr(o, v): struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)
    def gr(o):    return struct.unpack_from('<I', gph, o)[0]

    print("[FOGCCC] AXI-Lite regs @ 0x%08X   graph @ 0x%08X" % (REG_BASE, GRAPH_BASE))
    c0 = rr(R_CTRL)
    print("[FOGCCC] reset CTRL = 0x%08X  (done=%d)" % (c0, (c0 >> 31) & 1))

    # ---------- build graph: LIVE [0,L) + GARBAGE [L,n) ----------
    L = (n * 3) // 4
    REF_BASE = (HDR_BASE + n * 16 + 0xFFF) & ~0xFFF     # refs start after ALL headers
    task(5, "building object graph (%d objs, %d live + %d garbage)" % (n, L, n - L))
    t0 = time.time()
    buf = bytearray(GRAPH_SIZE)
    random.seed(42)
    ref_counts, ref_offs = [0] * n, [0] * n
    cur = REF_BASE
    for i in range(n):
        if i == 0:
            rc = avg_refs                      # root must actually point somewhere
        else:
            rc = random.randrange(0, avg_refs * 2 + 1)
        ref_counts[i] = rc
        ref_offs[i] = cur
        cur += rc * 4 + 4
    if cur > GRAPH_SIZE:
        print("ERROR: graph too large (%d > %d)" % (cur, GRAPH_SIZE)); return 1

    for i in range(n):
        o = HDR_BASE + i * 16
        struct.pack_into('<IIII', buf, o, i, ref_counts[i], GRAPH_BASE + ref_offs[i], 0)

    for i in range(n):
        o = ref_offs[i]
        lo, hi = (0, L) if i < L else (L, n)
        span = hi - lo
        for j in range(ref_counts[i]):
            if span > 1:
                t = lo + random.randrange(0, span)
                if t == i:
                    t = lo + ((t - lo + 1) % span)
            else:
                t = lo
            struct.pack_into('<I', buf, o + j * 4, t)
        struct.pack_into('<I', buf, o + ref_counts[i] * 4, 0xFFFFFFFF)

    task(25, "flushing graph to DDR")
    gph[0:GRAPH_SIZE] = bytes(buf)
    t_build = time.time() - t0
    print("[FOGCCC] graph: %d objects (%d live / %d garbage), %d refs, %d bytes (%.0f ms)"
          % (n, L, n - L, sum(ref_counts), cur, t_build * 1000))

    # ---------- programme registers ----------
    task(40, "programming registers")
    for i, rv in enumerate(roots):
        wr(R_ROOT_LIST + i * 4, rv)
    wr(R_ROOT_COUNT, len(roots))
    wr(R_OBJ_BASE,   GRAPH_BASE)
    wr(R_OBJ_COUNT,  n)

    wr(R_CTRL, CTRL_CLEAR_Q)
    time.sleep(0.001)
    task(50, "hardware BFS mark running")
    print("[FOGCCC] starting hardware mark ...")
    t0 = time.time()
    wr(R_CTRL, CTRL_START)

    deadline = time.time() + 5.0
    saw_busy = False
    while time.time() < deadline:
        if rr(R_CTRL) & CTRL_DONE:
            if saw_busy:
                break
        else:
            saw_busy = True
    t_hw = time.time() - t0

    ctrl   = rr(R_CTRL)
    hw_mkd = rr(R_MARKED)
    hw_cyc = rr(R_CYCLES)
    qh, qt = rr(R_Q_HEAD), rr(R_Q_TAIL)

    task(70, "reading hardware results")
    print()
    print("=== HARDWARE BFS MARK ===")
    print("  CTRL after     : 0x%08X  (done=%d)" % (ctrl, (ctrl >> 31) & 1))
    print("  marked objects : %d" % hw_mkd)
    print("  HW cycles      : %d   -> %.2f us @100 MHz" % (hw_cyc, hw_cyc * 0.01))
    print("  queue head/tail: %d / %d" % (qh, qt))
    print("  wall clock     : %.3f ms" % (t_hw * 1000))

    # ---------- software reference BFS ----------
    task(78, "software BFS reference")
    t0 = time.time()
    marked = bytearray(n)
    q = []
    for rv in roots:
        if rv < n and not marked[rv]:
            marked[rv] = 1; q.append(rv)
    head = 0
    while head < len(q):
        c = q[head]; head += 1
        rc = gr(HDR_BASE + c * 16 + 4)
        ro = gr(HDR_BASE + c * 16 + 8) - GRAPH_BASE
        for j in range(rc):
            t = gr(ro + j * 4)
            if t == 0xFFFFFFFF:
                break
            if t < n and not marked[t]:
                marked[t] = 1; q.append(t)
    t_sw = time.time() - t0
    sw_mkd = len(q)
    sw_garbage = sum(1 for x in q if x >= L)

    print()
    print("=== SOFTWARE BFS (Python reference) ===")
    print("  marked objects : %d" % sw_mkd)
    print("  wall clock     : %.3f ms" % (t_sw * 1000))

    print()
    if hw_mkd == sw_mkd:
        print("  ***** CORRECT: hardware marked == software marked (%d) *****" % sw_mkd)
    else:
        print("  ***** MISMATCH: hardware=%d  software=%d *****" % (hw_mkd, sw_mkd))
    if sw_garbage == 0:
        print("  ***** GARBAGE REGION CLEAN: 0 of %d garbage objects marked *****" % (n - L))
    else:
        print("  ***** WARNING: %d garbage objects were marked *****" % sw_garbage)
    if hw_cyc:
        hw_us = hw_cyc * 0.01
        sw_us = t_sw * 1e6
        print("  HW %.2f us   vs   Python SW %.0f us   ->  %.0fx faster"
              % (hw_us, sw_us, sw_us / hw_us))

    task(100, "done")
    regs.close(); gph.close(); os.close(fd)
    return 0

sys.exit(main())
