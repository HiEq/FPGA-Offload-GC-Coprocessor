#!/usr/bin/env python3
# ============================================================
# gc_test.py - FOGCCC reliability + performance sweep  (strict)
#
#   usage: python3 gc_test.py [maxN] [trials] [avg_refs]
#     maxN     : upper bound of object count per trial (default 4096;
#                hardware limit is 4096 = 12-bit ids / 4096x32 bitmap)
#     trials   : randomised runs (default 8)
#     avg_refs : average extra out-degree (default 2)
#
# WHY THIS TEST CANNOT GIVE A FALSE "OK"
# --------------------------------------
# 1) The LIVE region [0,L) is built as a SPANNING TREE from object 0 plus
#    extra random edges.  Therefore EVERY live object is reachable and the
#    expected mark count is KNOWN A PRIORI and equals L.
#    We do NOT merely compare "hardware count == software count"; both are
#    compared against L, the independently known truth.
# 2) The GARBAGE region [L,n) only ever points inside itself, so nothing in
#    it can be reached from the root.  Expected garbage marks = 0.
# 3) Completion is detected by the CYCLES register CHANGING, not by polling
#    DONE.  The engine clears DONE on start and sets it at the end, but it
#    finishes in ~40us while Python polling takes ~100us+, so a DONE poll
#    cannot distinguish "finished" from "never started" and would happily
#    read stale MARKED/CYCLES from the previous trial.  CYCLES is latched
#    only by S_DONE, so a change proves a run completed.
# 4) A trial is OK only if ALL of these hold:
#       engine really ran (CYCLES changed)
#       DONE is set afterwards
#       HW cycles >= 4096 (the mandatory bitmap-clear time)
#       hardware marked == L          (against known truth)
#       software marked == L          (reference must agree with truth)
#       software marked 0 garbage     (graph sanity)
#       L > 0                         (no degenerate graph)
#    Any failure is reported by name, never as OK.
# ============================================================
import mmap, os, struct, time, random, sys

REG_BASE   = 0x43C00000
GRAPH_BASE = 0x1E000000
GRAPH_SIZE = 0x100000          # 1 MiB

R_CTRL, R_OBJ_BASE, R_OBJ_COUNT, R_ROOT_COUNT = 0x00, 0x04, 0x08, 0x0C
R_MARKED, R_CYCLES, R_Q_HEAD, R_Q_TAIL, R_ROOT_LIST = 0x10, 0x14, 0x18, 0x1C, 0x40

CTRL_START, CTRL_CLEAR_Q, CTRL_DONE = 1, 4, (1 << 31)
HDR_BASE  = 0x0000
N_MAX_HW  = 4096               # 12-bit object ids + 4096x32 bitmap
MIN_CYCLES = 4096              # engine must at least clear the 4096-word bitmap

def task(pct, label):
    sys.stdout.write("@@TASK %d %s\n" % (pct, label)); sys.stdout.flush()

def main():
    maxN     = int(sys.argv[1]) if len(sys.argv) > 1 else 4096
    trials   = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    avg_refs = int(sys.argv[3]) if len(sys.argv) > 3 else 2
    if maxN > N_MAX_HW:
        print("NOTE: maxN %d clamped to hardware limit %d" % (maxN, N_MAX_HW))
        maxN = N_MAX_HW
    if avg_refs < 1: avg_refs = 1
    roots = [0]

    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=REG_BASE)
    gph  = mmap.mmap(fd, GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=GRAPH_BASE)

    def rr(o):    return struct.unpack_from('<I', regs, o)[0]
    def wr(o, v): struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)
    def gr(o):    return struct.unpack_from('<I', gph, o)[0]

    print("=" * 84)
    print(" FOGCCC  FPGA mark  --  strict reliability + performance sweep")
    print("   maxN=%d  trials=%d  avg_refs=%d   (HW limit %d, min cycles %d)"
          % (maxN, trials, avg_refs, N_MAX_HW, MIN_CYCLES))
    print("   expected count is KNOWN A PRIORI = L (live region), garbage must be 0")
    print("   regs @ 0x%08X  graph @ 0x%08X  reset CTRL = 0x%08X"
          % (REG_BASE, GRAPH_BASE, rr(R_CTRL)))
    print("=" * 84)

    rows = []
    for t in range(1, trials + 1):
        lo = min(maxN, max(64, maxN // 8))
        n  = random.randint(lo, maxN)
        L  = (n * 3) // 4
        REF_BASE = (HDR_BASE + n * 16 + 0xFFF) & ~0xFFF
        task(int(5 + 85.0 * (t - 1) / trials), "trial %d/%d  N=%d  (expect %d)" % (t, trials, n, L))

        # ---------- build graph ----------
        t0 = time.time()
        edges = [[] for _ in range(n)]
        # live: spanning tree 0 -> everything  (guarantees reachability)
        for i in range(1, L):
            p = random.randrange(0, i)
            edges[p].append(i)
            edges[i].append(p)
        # live: extra random edges (make it a real graph, not just a tree)
        for i in range(L):
            for _ in range(random.randrange(0, avg_refs + 1)):
                x = random.randrange(0, L)
                if x != i: edges[i].append(x)
        # garbage: edges only inside [L, n)
        for i in range(L, n):
            for _ in range(random.randrange(0, avg_refs * 2 + 1)):
                x = random.randrange(L, n)
                if x != i: edges[i].append(x)

        ref_counts = [len(e) for e in edges]
        ref_offs, cur = [0] * n, REF_BASE
        for i in range(n):
            ref_offs[i] = cur
            cur += ref_counts[i] * 4 + 4
        if cur > GRAPH_SIZE:
            print("  [%2d/%2d] N=%d graph too large (%d), skipped" % (t, trials, n, cur))
            continue
        buf = bytearray(cur)
        for i in range(n):
            o = HDR_BASE + i * 16
            struct.pack_into('<IIII', buf, o, i, ref_counts[i], GRAPH_BASE + ref_offs[i], 0)
        for i in range(n):
            o = ref_offs[i]
            for j, x in enumerate(edges[i]):
                struct.pack_into('<I', buf, o + j * 4, x)
            struct.pack_into('<I', buf, o + ref_counts[i] * 4, 0xFFFFFFFF)
        gph[0:len(buf)] = bytes(buf)
        t_build = time.time() - t0
        time.sleep(0.02)                       # let the uncached writes land before starting

        # ---------- hardware ----------
        for i, rv in enumerate(roots):
            wr(R_ROOT_LIST + i * 4, rv)
        wr(R_ROOT_COUNT, len(roots))
        wr(R_OBJ_BASE,   GRAPH_BASE)
        wr(R_OBJ_COUNT,  n)
        wr(R_CTRL, CTRL_CLEAR_Q)
        time.sleep(0.002)

        cyc0 = rr(R_CYCLES)
        mkd0 = rr(R_MARKED)
        t0 = time.time()
        wr(R_CTRL, CTRL_START)
        # completion = CYCLES changed (only S_DONE latches it)
        ran = False
        deadline = t0 + 3.0
        while time.time() < deadline:
            if rr(R_CYCLES) != cyc0:
                ran = True; break
            time.sleep(0.0002)
        hw_wall = time.time() - t0
        ctrl    = rr(R_CTRL)
        hw_mkd  = rr(R_MARKED)
        hw_cyc  = rr(R_CYCLES)
        hw_us   = hw_cyc * 0.01
        done    = (ctrl & CTRL_DONE) != 0

        # ---------- software reference ----------
        t0 = time.time()
        marked = bytearray(n); q = []
        for rv in roots:
            if rv < n and not marked[rv]:
                marked[rv] = 1; q.append(rv)
        head = 0
        while head < len(q):
            c = q[head]; head += 1
            rc = gr(HDR_BASE + c * 16 + 4)
            ro = gr(HDR_BASE + c * 16 + 8) - GRAPH_BASE
            for j in range(rc):
                x = gr(ro + j * 4)
                if x == 0xFFFFFFFF: break
                if x < n and not marked[x]:
                    marked[x] = 1; q.append(x)
        sw_s    = time.time() - t0
        sw_mkd  = len(q)
        sw_garb = sum(1 for x in q if x >= L)

        # ---------- STRICT verdict ----------
        fails = []
        if L <= 0:               fails.append("DEGENERATE")
        if not ran:              fails.append("NO-RUN")
        if not done:             fails.append("DONE-LOW")
        if not (hw_cyc >= MIN_CYCLES): fails.append("CYCLES<%d" % MIN_CYCLES)
        if hw_mkd != L:          fails.append("HW!=(%d vs %d)" % (hw_mkd, L))
        if sw_mkd != L:          fails.append("SW!=(%d vs %d)" % (sw_mkd, L))
        if sw_garb != 0:         fails.append("GARBAGE=%d" % sw_garb)
        ok = (len(fails) == 0)
        verdict = "OK" if ok else "FAIL:" + ",".join(fails)

        speed = (sw_s * 1e6 / hw_us) if hw_us > 0 else 0.0
        rows.append(dict(t=t, n=n, live=L, garb=n - L, cyc=hw_cyc, hw_us=hw_us,
                         sw_ms=sw_s * 1000, speed=speed, hw=hw_mkd, sw=sw_mkd,
                         g=sw_garb, exp=L, ok=ok, verdict=verdict))
        print("  [%2d/%2d] N=%4d exp=%4d | HW %9.2f us (%d cyc) | SW %8.2f ms | %6.1fx | %s"
              % (t, trials, n, L, hw_us, hw_cyc, sw_s * 1000, speed, verdict))

    task(96, "summarising")

    # ---------- summary ----------
    print()
    print("=" * 84)
    print(" SUMMARY   (expected = live-region size L, garbage must be 0)")
    print("=" * 84)
    if not rows:
        print("  no trials completed"); return 1
    hdr = " %5s %6s %6s %6s %12s %10s %9s %8s %6s %6s  %s" % (
          "trial", "N", "exp", "garb", "HW cycles", "HW us", "SW ms",
          "speedup", "HWmk", "SWmk", "verdict")
    print(hdr)
    print(" " + "-" * (len(hdr) - 1))
    for r in rows:
        print(" %5d %6d %6d %6d %12d %10.2f %9.2f %7.1fx %6d %6d  %s"
              % (r['t'], r['n'], r['exp'], r['garb'], r['cyc'], r['hw_us'],
                 r['sw_ms'], r['speed'], r['hw'], r['sw'], r['verdict']))
    print(" " + "-" * (len(hdr) - 1))
    nok   = sum(1 for r in rows if r['ok'])
    tot_cyc = sum(r['cyc'] for r in rows)
    tot_hw  = sum(r['hw_us'] for r in rows)
    tot_sw  = sum(r['sw_ms'] for r in rows)
    sp = [r['speed'] for r in rows if r['ok']]
    print("  trials                : %d" % len(rows))
    print("  PASSED (all invariants): %d/%d" % (nok, len(rows)))
    print("  total HW cycles        : %d  (= %.2f us @100MHz)" % (tot_cyc, tot_hw))
    print("  total SW (Python)      : %.2f ms" % tot_sw)
    if sp:
        print("  speedup min/avg/max    : %.1fx / %.1fx / %.1fx"
              % (min(sp), sum(sp) / len(sp), max(sp)))
    else:
        print("  speedup                : n/a (no passing trial)")
    print("  N range                : %d .. %d" % (min(r['n'] for r in rows), max(r['n'] for r in rows)))
    print()
    print("  NOTE: 'SW ms' is an interpreted-Python reference BFS used as a")
    print("        correctness oracle + rough CPU cost bound, NOT an optimised")
    print("        C implementation.  The rigorous hardware metric is the")
    print("        deterministic HW cycle count @100MHz.")
    print("=" * 84)

    task(100, "done")
    regs.close(); gph.close(); os.close(fd)
    return 0 if nok == len(rows) else 1

sys.exit(main())
