#!/usr/bin/env python3
# ============================================================
# abort_test.py - board-level test of CTRL[3] (abort)
#
#   usage: python3 abort_test.py [N] [avg_refs] [--seed N]
#     N        : object count (default 4096 = HW limit)
#     avg_refs : average extra out-degree (default 2)
#     --seed   : RNG seed (printed; replay with the same value)
#
# 判据:
#   T1 基线    完整跑一次: DONE=1, marked==L, STATUS=0, 位图逐位回读 == SW
#   T2 控制组  START+200us, 不写 abort: DONE 必须在 30 ms 内置起
#              (= T3 的反证: 同样的时序, 没有 abort 就一定跑完)
#   T3 abort   START+200us 写 CTRL[3]: 30 ms 内 DONE 必须始终为 0
#   T4 恢复    同图再跑一次: marked==L, STATUS=0, 位图逐位回读 == SW
#   T5 换图    abort 之后立刻换一张【不同规模】的图, 只写 START (不写 CLEAR_Q,
#              与驱动一致): 必须只标出新一轮的活跃集, STATUS==0。
#              这条是真正危险的那条路: 上一轮残留的队列项若被继承, 会多标。
#
# 注意: MARKED / CYCLES 只在进入 DONE 时锁存, 所以 abort 之后它们仍是上一轮的
#       旧值, 不能用来看"打断到哪一步"; 判定只用 DONE 位 + 恢复后的结果。
#
# 先验期望值: 生成器保证活跃区 [0,L) 由对象 0 的生成树连通, 垃圾区 [L,N)
#             只指向自身 => 期望标记数恰好 = L。SW BFS 独立复核一遍。
# ============================================================
import mmap, os, struct, sys, time, random

REG_BASE   = 0x43C00000
GRAPH_BASE = 0x1E000000
GRAPH_SIZE = 0x100000          # 1 MiB

R_CTRL, R_OBJ_BASE, R_OBJ_COUNT, R_ROOT_COUNT = 0x00, 0x04, 0x08, 0x0C
R_MARKED, R_CYCLES, R_Q_HEAD, R_Q_TAIL = 0x10, 0x14, 0x18, 0x1C
R_STATUS, R_BM_ADDR, R_BM_DATA = 0x20, 0x24, 0x28
R_MAGIC, R_VERSION, R_ROOT_LIST = 0x30, 0x34, 0x40

CTRL_START, CTRL_CLEAR_Q, CTRL_ABORT, CTRL_DONE = 1, 4, 8, (1 << 31)
HDR_BASE  = 0x0000
N_MAX_HW  = 4096
MIN_CYCLES = 4096

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
    n        = int(argv[0]) if len(argv) > 0 else 4096
    avg_refs = int(argv[1]) if len(argv) > 1 else 2
    if n > N_MAX_HW:
        print("NOTE: N %d clamped to hardware limit %d" % (n, N_MAX_HW)); n = N_MAX_HW
    if avg_refs < 1: avg_refs = 1
    if seed is None:
        seed = int(time.time() * 1000) & 0x7FFFFFFF
    rng = random.Random(seed)
    roots = [0]

    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=REG_BASE)
    gph  = mmap.mmap(fd, GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=GRAPH_BASE)

    def rr(o):    return struct.unpack_from('<I', regs, o)[0]
    def wr(o, v): struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)
    def gr(o):    return struct.unpack_from('<I', gph, o)[0]

    print("=" * 84)
    print(" FOGCCC  CTRL[3] abort  --  board-level test")
    print("   N=%d  avg_refs=%d  seed=%d" % (n, avg_refs, seed))
    print("   regs @ 0x%08X  graph @ 0x%08X" % (REG_BASE, GRAPH_BASE))
    magic = rr(R_MAGIC); ver = rr(R_VERSION)
    print("   MAGIC = 0x%08X   VERSION = 0x%08X" % (magic, ver))
    if magic != 0x47434343:
        print("   FAIL: MAGIC mismatch -- bitstream and software are not paired")
        return 1
    print("=" * 84)

    # ---------- graph builder (same generator as gc_test.py) ----------
    state = {'marked': None, 'n': 0, 'L': 0}

    def build(nn, do_clear_q=False):
        L = (nn * 3) // 4
        edges = [[] for _ in range(nn)]
        for i in range(1, L):
            p = rng.randrange(0, i)
            edges[p].append(i); edges[i].append(p)
        for i in range(L):
            for _ in range(rng.randrange(0, avg_refs + 1)):
                x = rng.randrange(0, L)
                if x != i: edges[i].append(x)
        for i in range(L, nn):
            for _ in range(rng.randrange(0, avg_refs * 2 + 1)):
                x = rng.randrange(L, nn)
                if x != i: edges[i].append(x)

        ref_counts = [len(e) for e in edges]
        REF_BASE = (HDR_BASE + nn * 16 + 0xFFF) & ~0xFFF
        ref_offs, cur = [0] * nn, REF_BASE
        for i in range(nn):
            ref_offs[i] = cur
            cur += ref_counts[i] * 4 + 4
        if cur > GRAPH_SIZE:
            raise SystemExit("graph too large (%d > %d)" % (cur, GRAPH_SIZE))
        buf = bytearray(cur)
        for i in range(nn):
            struct.pack_into('<IIII', buf, HDR_BASE + i * 16, i, ref_counts[i], GRAPH_BASE + ref_offs[i], 0)
        for i in range(nn):
            o = ref_offs[i]
            for j, x in enumerate(edges[i]):
                struct.pack_into('<I', buf, o + j * 4, x)
            struct.pack_into('<I', buf, o + ref_counts[i] * 4, 0xFFFFFFFF)
        gph[0:len(buf)] = bytes(buf)
        time.sleep(0.02)                        # let the uncached writes land

        # independent oracle: SW BFS over the same graph
        marked = bytearray(nn); q = []
        for rv in roots:
            if rv < nn and not marked[rv]:
                marked[rv] = 1; q.append(rv)
        head = 0
        while head < len(q):
            c = q[head]; head += 1
            rc = gr(HDR_BASE + c * 16 + 4)
            ro = gr(HDR_BASE + c * 16 + 8) - GRAPH_BASE
            for j in range(rc):
                x = gr(ro + j * 4)
                if x == 0xFFFFFFFF: break
                if x < nn and not marked[x]:
                    marked[x] = 1; q.append(x)
        state['marked'] = marked; state['n'] = nn; state['L'] = L

        for i, rv in enumerate(roots):
            wr(R_ROOT_LIST + i * 4, rv)
        wr(R_ROOT_COUNT, len(roots))
        wr(R_OBJ_BASE,   GRAPH_BASE)
        wr(R_OBJ_COUNT,  nn)
        if do_clear_q:
            wr(R_CTRL, CTRL_CLEAR_Q)
            time.sleep(0.002)
        return L, len(q)

    def wait_done(ms):
        end = time.time() + ms / 1000.0
        while time.time() < end:
            if rr(R_CTRL) & CTRL_DONE:
                return True
        return False

    def read_bit(obj):
        wr(R_BM_ADDR, obj)
        rr(R_BM_ADDR)                       # flush the posted write
        return (rr(R_BM_DATA) >> (obj & 31)) & 1

    def readback_matches():
        marked = state['marked']; nn = state['n']
        bad = 0
        for obj in range(nn):
            hb = read_bit(obj)
            if hb != marked[obj]:
                bad += 1
                if bad <= 3:
                    print("   bitmap mismatch at obj %d: hw=%d sw=%d" % (obj, hb, marked[obj]))
        return bad

    fails = []

    # ---------- T1 baseline ----------
    task(15, "T1 baseline full run")
    L, sw = build(n, do_clear_q=True)
    print("   graph: N=%d L=%d  SW BFS=%d" % (n, L, sw))
    if sw != L: fails.append("T1 SW BFS %d != L %d" % (sw, L))
    wr(R_CTRL, CTRL_START)
    t0 = time.time(); ok = wait_done(300); t1 = time.time()
    mkd = rr(R_MARKED); cyc = rr(R_CYCLES); st = rr(R_STATUS)
    print("   T1: done=%s marked=%d cycles=%d status=0x%X wall=%.2f ms"
          % (ok, mkd, cyc, st, (t1 - t0) * 1000))
    if not ok:      fails.append("T1 no DONE")
    if mkd != L:    fails.append("T1 marked=%d != %d" % (mkd, L))
    if st != 0:     fails.append("T1 status=0x%X" % st)
    if cyc < MIN_CYCLES: fails.append("T1 cycles<MIN")
    bad = readback_matches()
    print("   T1: bitmap readback mismatches = %d" % bad)
    if bad: fails.append("T1 bitmap %d mismatches" % bad)
    cyc_ref = cyc

    # ---------- T2 control: same timing, no abort ----------
    task(30, "T2 control (no abort)")
    wr(R_CTRL, CTRL_START)
    time.sleep(0.0002)                      # 200 us
    ok = wait_done(30)
    ctrl = rr(R_CTRL); mkd = rr(R_MARKED); st = rr(R_STATUS)
    print("   T2: DONE=%s marked=%d status=0x%X  (expect DONE=1, marked=%d)"
          % (ok, mkd, st, L))
    if not ok:      fails.append("T2 control did not finish (test cannot distinguish abort)")
    if mkd != L:    fails.append("T2 marked=%d != %d" % (mkd, L))
    if st != 0:     fails.append("T2 status=0x%X" % st)

    # ---------- T3 abort ----------
    task(45, "T3 abort mid-run")
    wr(R_CTRL, CTRL_START)
    time.sleep(0.0002)
    st_pre = rr(R_STATUS)                   # was the flag already set before the abort?
    wr(R_CTRL, CTRL_ABORT)                  # CTRL[3]
    st_post = rr(R_STATUS)                  # ... and immediately after it?
    t0 = time.time()
    done_seen = False; reads = 0
    while time.time() - t0 < 0.030:         # 30 ms = many full runs
        reads += 1
        if rr(R_CTRL) & CTRL_DONE:
            done_seen = True; break
    st = rr(R_STATUS); mkd_stale = rr(R_MARKED); cyc_stale = rr(R_CYCLES)
    print("   T3: STATUS before abort = 0x%X, right after = 0x%X"
          % (st_pre, st_post))
    print("   T3: DONE after abort = %s (%d reads in %.1f ms)"
          % (done_seen, reads, (time.time() - t0) * 1000))
    print("   T3: STATUS=0x%X  MARKED=%d CYCLES=%d (stale by design: latched at DONE)"
          % (st, mkd_stale, cyc_stale))
    if done_seen:    fails.append("T3 DONE set after abort (abort did not stop the run)")
    if st != 0:      fails.append("T3 status=0x%X (abort must not set error flags)" % st)

    # ---------- T4 recovery on the same graph ----------
    task(60, "T4 recovery run after abort")
    wr(R_CTRL, CTRL_START)
    ok = wait_done(300)
    mkd = rr(R_MARKED); cyc = rr(R_CYCLES); st = rr(R_STATUS)
    print("   T4: done=%s marked=%d cycles=%d status=0x%X (expect marked=%d, status=0)"
          % (ok, mkd, cyc, st, L))
    if not ok:      fails.append("T4 no DONE after abort (engine not reusable)")
    if mkd != L:    fails.append("T4 marked=%d != %d" % (mkd, L))
    if st != 0:     fails.append("T4 status=0x%X" % st)
    if cyc < MIN_CYCLES: fails.append("T4 cycles<MIN")

    task(70, "T4 bitmap readback")
    bad = readback_matches()
    print("   T4: bitmap readback mismatches = %d (partial bitmap from T3 must be gone)" % bad)
    if bad: fails.append("T4 bitmap %d mismatches" % bad)

    # ---------- T5 abort, then a DIFFERENT graph, START only ----------
    task(80, "T5 abort, then a different graph")
    wr(R_CTRL, CTRL_START)
    time.sleep(0.0002)
    wr(R_CTRL, CTRL_ABORT)
    time.sleep(0.002)
    n2 = max(64, n // 2)
    L2, sw2 = build(n2, do_clear_q=False)   # no CLEAR_Q: exactly what the driver does
    print("   T5: new graph N=%d L=%d  SW BFS=%d  (queue must have been flushed by abort)"
          % (n2, L2, sw2))
    wr(R_CTRL, CTRL_START)
    ok = wait_done(300)
    mkd = rr(R_MARKED); st = rr(R_STATUS)
    print("   T5: done=%s marked=%d status=0x%X (expect marked=%d, status=0)"
          % (ok, mkd, st, L2))
    if not ok:      fails.append("T5 no DONE")
    if mkd != L2:   fails.append("T5 marked=%d != %d (inherited the aborted run)" % (mkd, L2))
    if st != 0:     fails.append("T5 status=0x%X (aborted run leaked into the new graph)" % st)
    bad = readback_matches()
    print("   T5: bitmap readback mismatches = %d" % bad)
    if bad: fails.append("T5 bitmap %d mismatches" % bad)

    # ---------- summary ----------
    task(96, "summarising")
    print()
    print("=" * 84)
    print(" SUMMARY   abort test (N=%d then %d, seed=%d)" % (n, n2, seed))
    print("=" * 84)
    for f in fails:
        print("   FAIL: " + f)
    if fails:
        print("   RESULT: FAIL (%d)" % len(fails))
        return 1
    print("   RESULT: PASS  (T1 baseline, T2 control, T3 abort, T4 recovery, T5 new graph)")
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
