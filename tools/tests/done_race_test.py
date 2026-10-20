#!/usr/bin/env python3
# ============================================================
# done_race_test.py - posted-write / stale-DONE race (AGENTS gap 9)
#
#   usage: python3 done_race_test.py [--iters N] [--flip-iters N] [--n N]
#
# 背景: START 是 posted AXI-Lite 写。写完立刻读 CTRL 时, 这个读可能先于写生效,
#       于是读到【上一轮】的 DONE=1, 把旧结果当成新结果返回。
#       驱动现在的做法是: 写完 START 先读一次 CTRL 把写刷下去, 再 usleep(1), 然后轮询。
#
# 实验 (三段, 同一块板、同一份位流):
#   P1 朴素读   START 后立刻读一次 CTRL, 统计 DONE 仍为 1 的次数。
#   P2 早退危险 用轮询的方式跑: START 后直接轮询 DONE。若第一拍就读到 DONE,
#              立即记录, 并核对 MARKED 是否仍是上一轮的值 (= 会返回旧结果)。
#              这段跑 30 ms 内必须自己收敛, 每轮结束后等引擎真正完成再进入下一轮。
#   P3 驱动顺序  与驱动一致: 读回 CTRL + usleep(1) + 轮询 DONE; 交替用两种规模
#              (L=768 / L=2304) 跑, 每轮返回值必须等于本轮自己的 L。
#              若读到 stale DONE, 会返回上一轮的 L -> 立即记 mismatch。
#
# 判据:
#   P1/P2 是观测 (计数, 不断言) -- 命中 0 次也照样记录, 说明在当前硬件/连接上
#        复现不出来, 缓解措施仍是"有理由但未证实"。
#   P3 必须 0 mismatch -> 否则 FAIL。
# ============================================================
import mmap, os, struct, sys, time, random

REG_BASE   = 0x43C00000
GRAPH_BASE = 0x1E000000
GRAPH_SIZE = 0x100000

R_CTRL, R_OBJ_BASE, R_OBJ_COUNT, R_ROOT_COUNT = 0x00, 0x04, 0x08, 0x0C
R_MARKED, R_CYCLES = 0x10, 0x14
R_STATUS, R_MAGIC, R_VERSION, R_ROOT_LIST = 0x20, 0x30, 0x34, 0x40

CTRL_START, CTRL_CLEAR_Q, CTRL_ABORT, CTRL_DONE = 1, 4, 8, (1 << 31)
HDR_BASE = 0x0000

def task(pct, label):
    sys.stdout.write("@@TASK %d %s\n" % (pct, label)); sys.stdout.flush()

def main():
    argv = sys.argv[1:]
    iters      = 300
    flip_iters = 20
    if '--iters' in argv:
        iters = int(argv[argv.index('--iters') + 1])
    if '--flip-iters' in argv:
        flip_iters = int(argv[argv.index('--flip-iters') + 1])
    seed = 20261019
    rng = random.Random(seed)

    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=REG_BASE)
    gph  = mmap.mmap(fd, GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=GRAPH_BASE)

    def rr(o):    return struct.unpack_from('<I', regs, o)[0]
    def wr(o, v): struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)
    def gr(o):    return struct.unpack_from('<I', gph, o)[0]

    print("=" * 84)
    print(" FOGCCC  stale-DONE race  --  board-level experiment (AGENTS gap 9)")
    print("   iters(P1/P2)=%d  flip-iters(P3)=%d  seed=%d" % (iters, flip_iters, seed))
    magic = rr(R_MAGIC); ver = rr(R_VERSION)
    print("   MAGIC = 0x%08X   VERSION = 0x%08X" % (magic, ver))
    if magic != 0x47434343:
        print("   FAIL: MAGIC mismatch -- bitstream and software are not paired")
        return 1
    print("=" * 84)

    def build(n, avg_refs=2):
        L = (n * 3) // 4
        edges = [[] for _ in range(n)]
        for i in range(1, L):
            p = rng.randrange(0, i)
            edges[p].append(i); edges[i].append(p)
        for i in range(L):
            for _ in range(rng.randrange(0, avg_refs + 1)):
                x = rng.randrange(0, L)
                if x != i: edges[i].append(x)
        for i in range(L, n):
            for _ in range(rng.randrange(0, avg_refs * 2 + 1)):
                x = rng.randrange(L, n)
                if x != i: edges[i].append(x)
        ref_counts = [len(e) for e in edges]
        REF_BASE = (HDR_BASE + n * 16 + 0xFFF) & ~0xFFF
        ref_offs, cur = [0] * n, REF_BASE
        for i in range(n):
            ref_offs[i] = cur
            cur += ref_counts[i] * 4 + 4
        buf = bytearray(cur)
        for i in range(n):
            struct.pack_into('<IIII', buf, HDR_BASE + i * 16, i, ref_counts[i], GRAPH_BASE + ref_offs[i], 0)
        for i in range(n):
            o = ref_offs[i]
            for j, x in enumerate(edges[i]):
                struct.pack_into('<I', buf, o + j * 4, x)
            struct.pack_into('<I', buf, o + ref_counts[i] * 4, 0xFFFFFFFF)
        gph[0:len(buf)] = bytes(buf)
        time.sleep(0.02)
        # independent oracle: SW BFS over the same graph
        marked = bytearray(n); q = [0]; marked[0] = 1
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
        return L, len(q)

    def setup(n, L):
        wr(R_ROOT_LIST, 0)
        wr(R_ROOT_COUNT, 1)
        wr(R_OBJ_BASE,   GRAPH_BASE)
        wr(R_OBJ_COUNT,  n)
        wr(R_CTRL, CTRL_CLEAR_Q)
        time.sleep(0.02)                    # let the uncached graph writes land

    def wait_done(ms):
        end = time.time() + ms / 1000.0
        while time.time() < end:
            if rr(R_CTRL) & CTRL_DONE:
                return True
        return False

    fails = []

    # ---------- P1: naive single read immediately after START ----------
    task(10, "P1 naive read")
    n0 = 4096
    L0, sw0 = build(n0); setup(n0, L0)
    # warm-up run (so DONE starts at 1, which is the dangerous precondition)
    warm_ok = False
    wr(R_CTRL, CTRL_START); warm_ok = wait_done(300)
    print("   warm-up: done=%s marked=%d" % (warm_ok, rr(R_MARKED)))
    if not warm_ok:
        print("   FAIL: warm-up run did not complete"); return 1
    p1_hits = 0; p1_checked = 0
    for _ in range(iters):
        wr(R_CTRL, CTRL_START)
        p1_checked += 1
        if rr(R_CTRL) & CTRL_DONE:
            p1_hits += 1
        if not wait_done(300):              # let the real run finish before the next one
            fails.append("P1 iteration did not complete"); break
    print("   P1: %d/%d first reads saw DONE=1 (stale hit rate %.2f%%)"
          % (p1_hits, p1_checked, 100.0 * p1_hits / max(1, p1_checked)))

    # ---------- P2: poll-early-return hazard ----------
    task(35, "P2 early return hazard")
    p2_early = 0; p2_stale_val = 0; p2_checked = 0
    prev_L = L0
    for _ in range(iters):
        wr(R_CTRL, CTRL_START)
        p2_checked += 1
        if rr(R_CTRL) & CTRL_DONE:          # would be an early return in a naive driver
            p2_early += 1
            if rr(R_MARKED) == prev_L:      # the value would be the previous run's
                p2_stale_val += 1
        if not wait_done(300):
            fails.append("P2 iteration did not complete"); break
        prev_L = rr(R_MARKED)
    print("   P2: %d/%d early returns; %d of them returned the previous run's MARKED"
          % (p2_early, p2_checked, p2_stale_val))

    # ---------- P3: the driver's sequence, alternating sizes ----------
    task(60, "P3 driver sequence, alternating sizes")
    mismatches = 0; checked = 0
    sizes = [1024, 3072]
    for it in range(flip_iters):
        n = sizes[it % 2]
        L, sw = build(n); setup(n, L)
        wr(R_CTRL, CTRL_START)
        _ = rr(R_CTRL)                       # the driver's flush read
        time.sleep(0.000001)                 # usleep(1)
        ok = wait_done(300)
        mkd = rr(R_MARKED); st_raw = rr(R_STATUS)
        st = st_raw & 0xF                    # error bits; bit4 is engine idle
        idle = (st_raw >> 4) & 1
        checked += 1
        good = ok and (mkd == sw) and (st == 0) and idle
        if not good:
            mismatches += 1
            print("   P3[%2d]: N=%4d expect %4d (SW %4d) -> done=%s marked=%d status=0x%X  MISMATCH"
                  % (it, n, L, sw, ok, mkd, st))
        elif it < 4 or it >= flip_iters - 2:
            print("   P3[%2d]: N=%4d expect %4d (SW %4d) -> marked=%d status=0x%X  ok"
                  % (it, n, L, sw, mkd, st))
    print("   P3: %d/%d runs returned their own L" % (checked - mismatches, checked))
    if mismatches:
        fails.append("P3 %d stale/incorrect results" % mismatches)

    # ---------- summary ----------
    task(96, "summarising")
    print()
    print("=" * 84)
    print(" SUMMARY   stale-DONE experiment")
    print("=" * 84)
    print("   P1 naive first-read hits        : %d/%d  (observed, not asserted)" % (p1_hits, p1_checked))
    print("   P2 poll early-return hits       : %d/%d (stale value: %d)  (observed, not asserted)"
          % (p2_early, p2_checked, p2_stale_val))
    print("   P3 driver-order mismatches      : %d/%d  (the pass/fail criterion)" % (mismatches, checked))
    for f in fails:
        print("   FAIL: " + f)
    if fails:
        print("   RESULT: FAIL")
        return 1
    print("   RESULT: PASS (P3 invariant: the driver order always returned the current run's result)")
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
