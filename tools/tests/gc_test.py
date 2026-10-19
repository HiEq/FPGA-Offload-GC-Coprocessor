#!/usr/bin/env python3
# ============================================================
# gc_test.py - FOGCCC reliability + performance sweep
#
#   usage: python3 gc_test.py [maxN] [trials] [avg_refs] [--seed N]
#     maxN     : object-count upper bound per trial (default 4096 = hardware limit)
#     trials   : randomised runs (default 8)
#     avg_refs : average extra out-degree (default 2)
#     --seed   : RNG seed; printed when omitted, so runs can be replayed:
#                python3 gc_test.py 4096 8 2 --seed 12345
#
# 判据:
#   1) 活跃区 [0,L): 对象 0 的生成树加随机边, 期望标记数 = L
#   2) 垃圾区 [L,n): 只指向自身, 期望标记数 = 0
#   3) 完成判定: 读 CYCLES 变化, 不轮询 DONE
# ============================================================
import mmap, os, struct, time, random, sys

REG_BASE   = 0x43C00000
GRAPH_BASE = 0x1E000000
GRAPH_SIZE = 0x100000          # 1 MiB

R_CTRL, R_OBJ_BASE, R_OBJ_COUNT, R_ROOT_COUNT = 0x00, 0x04, 0x08, 0x0C
R_MARKED, R_CYCLES, R_Q_HEAD, R_Q_TAIL, R_ROOT_LIST, R_STATUS = 0x10, 0x14, 0x18, 0x1C, 0x40, 0x20
R_BM_ADDR, R_BM_DATA = 0x24, 0x28

CTRL_START, CTRL_CLEAR_Q, CTRL_DONE = 1, 4, (1 << 31)
HDR_BASE  = 0x0000
N_MAX_HW  = 4096               # 12-bit object ids + 4096x32 bitmap
MIN_CYCLES = 4096              # engine must at least clear the 4096-word bitmap

def task(pct, label):
    sys.stdout.write("@@TASK %d %s\n" % (pct, label)); sys.stdout.flush()

def main():
    argv = sys.argv[1:]
    seed = None
    if '--seed' in argv:
        i = argv.index('--seed')
        if i + 1 >= len(argv):
            raise SystemExit('--seed needs a value')
        seed = int(argv[i + 1]); del argv[i:i + 2]
    maxN     = int(argv[0]) if len(argv) > 0 else 4096
    trials   = int(argv[1]) if len(argv) > 1 else 8
    avg_refs = int(argv[2]) if len(argv) > 2 else 2
    if seed is None:
        seed = int(time.time() * 1000) & 0x7FFFFFFF
    rng = random.Random(seed)
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
    print("   seed=%d   (replay exactly: --seed %d)" % (seed, seed))
    print("   expected count is KNOWN A PRIORI = L (live region), garbage must be 0")
    print("   regs @ 0x%08X  graph @ 0x%08X  reset CTRL = 0x%08X"
          % (REG_BASE, GRAPH_BASE, rr(R_CTRL)))
    # Bitstream/software pairing check: MAGIC (0x30) and VERSION (0x34).
    _magic = rr(0x30)
    _ver   = rr(0x34)
    print("   MAGIC = 0x%08X   VERSION = 0x%08X" % (_magic, _ver))
    if _magic != 0x47434343:
        print("   ERROR: MAGIC mismatch (0x%08X) -- bitstream and software are not paired" % _magic)
        return 1
    print("=" * 84)

    rows = []
    skipped = 0
    for t in range(1, trials + 1):
        lo = min(maxN, max(64, maxN // 8))
        n  = rng.randint(lo, maxN)
        L  = (n * 3) // 4
        REF_BASE = (HDR_BASE + n * 16 + 0xFFF) & ~0xFFF
        task(int(5 + 85.0 * (t - 1) / trials), "trial %d/%d  N=%d  (expect %d)" % (t, trials, n, L))

        # ---------- build graph ----------
        t0 = time.time()
        edges = [[] for _ in range(n)]
        # live: spanning tree 0 -> everything  (guarantees reachability)
        for i in range(1, L):
            p = rng.randrange(0, i)
            edges[p].append(i)
            edges[i].append(p)
        # live: extra random edges (make it a real graph, not just a tree)
        for i in range(L):
            for _ in range(rng.randrange(0, avg_refs + 1)):
                x = rng.randrange(0, L)
                if x != i: edges[i].append(x)
        # garbage: edges only inside [L, n)
        for i in range(L, n):
            for _ in range(rng.randrange(0, avg_refs * 2 + 1)):
                x = rng.randrange(L, n)
                if x != i: edges[i].append(x)

        ref_counts = [len(e) for e in edges]
        ref_offs, cur = [0] * n, REF_BASE
        for i in range(n):
            ref_offs[i] = cur
            cur += ref_counts[i] * 4 + 4
        if cur > GRAPH_SIZE:
            print("  [%2d/%2d] N=%d graph too large (%d), skipped" % (t, trials, n, cur))
            skipped += 1
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
        # START is a posted write: read CTRL once to flush it, then poll DONE.
        # (Polling CYCLES alone mis-reported NO-RUN when two runs happened to
        # produce the same cycle count.)
        rd_ctrl_flush = rr(R_CTRL)
        time.sleep(0.0002)
        ran = False
        deadline = t0 + 3.0
        while time.time() < deadline:
            if rr(R_CTRL) & CTRL_DONE:
                ran = True; break
            time.sleep(0.0002)
        hw_wall = time.time() - t0
        ctrl    = rr(R_CTRL)
        st      = rr(R_STATUS)          # [0]=overflow [1]=AXI err [2]=desync [3]=bad hdr
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

        # ---------- bitmap readback: compare the SET, not just the count ----------
        # MARKED can be right while the bitmap holds the wrong objects.
        bm_bad = 0
        for o in range(n):
            wr(R_BM_ADDR, o)
            rr(R_BM_ADDR)
            hb = (rr(R_BM_DATA) >> (o & 31)) & 1
            if hb != marked[o]:
                bm_bad += 1
                if bm_bad <= 3:
                    print("      bitmap mismatch obj %d hw=%d sw=%d" % (o, hb, marked[o]))

        # ---------- STRICT verdict ----------
        fails = []
        if L <= 0:               fails.append("DEGENERATE")
        if not ran:              fails.append("NO-RUN")
        if not done:             fails.append("DONE-LOW")
        if st != 0:              fails.append("STATUS=0x%X" % st)
        if not (hw_cyc >= MIN_CYCLES): fails.append("CYCLES<%d" % MIN_CYCLES)
        if hw_mkd != L:          fails.append("HW!=(%d vs %d)" % (hw_mkd, L))
        if sw_mkd != L:          fails.append("SW!=(%d vs %d)" % (sw_mkd, L))
        if sw_garb != 0:         fails.append("GARBAGE=%d" % sw_garb)
        if bm_bad != 0:          fails.append("BITMAP=%d" % bm_bad)
        ok = (len(fails) == 0)
        verdict = "OK" if ok else "FAIL:" + ",".join(fails)

        speed = (sw_s * 1e6 / hw_us) if hw_us > 0 else 0.0
        rows.append(dict(t=t, n=n, live=L, garb=n - L, cyc=hw_cyc, hw_us=hw_us, build=t_build,
                         sw_ms=sw_s * 1000, speed=speed, hw=hw_mkd, sw=sw_mkd,
                         g=sw_garb, exp=L, ok=ok, verdict=verdict))
        print("  [%2d/%2d] N=%4d exp=%4d | HW %9.2f us (%d cyc) | SW %8.2f ms | %6.1fx | build %6.1f ms | %s"
              % (t, trials, n, L, hw_us, hw_cyc, sw_s * 1000, speed, t_build * 1000, verdict))

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
    print("  skipped (graph too big): %d" % skipped)
    print("  seed                  : %d   (replay: --seed %d)" % (seed, seed))
    print("  PASSED (all invariants): %d/%d" % (nok, len(rows)))
    print("  total HW cycles        : %d  (= %.2f us @100MHz)" % (tot_cyc, tot_hw))
    print("  end-to-end note        : graph build+write (Python) %.1f ms avg vs HW %.3f ms avg"
          % (1000.0 * sum(r["build"] for r in rows) / len(rows), tot_hw / len(rows)))
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
    return 0 if (nok == len(rows) and skipped == 0) else 1

sys.exit(main())
