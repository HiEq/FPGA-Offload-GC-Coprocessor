#!/usr/bin/env python3
# ============================================================
# abort_sweep.py - abort at many points of a run, not just one
#
#   usage: python3 abort_sweep.py [N] [avg_refs] [--seed N]
#
# abort_test 只在 ~200 us（标记阶段）打断一次; 打断点会影响 STATUS[1],
# 因此按相位各扫一遍:
#   位图清零 (0~41 us) / 根处理 / 头部读 / 引用读 / 收尾
#
# 每个相位:
#   1) START, 忙等到 d us, 先读一次 STATUS, 再写 CTRL[3]
#   2) 20 ms 内 DONE 必须始终为 0   (若写 abort 之前就已经 DONE=1, 记为 skipped)
#   3) 紧接着完整跑一次: marked == L, STATUS == 0, 位图逐位回读 == SW
#
# 判据:
#   - 每个未跳过的相位都必须被 abort 停住
#   - 每个相位之后的恢复都必须精确
#   - abort 后的 STATUS 逐相位打印 (观测项, 不做断言 -- 见 AGENTS gap 13)
# ============================================================
import mmap, os, struct, sys, time, random

REG_BASE   = 0x43C00000
GRAPH_BASE = 0x1E000000
GRAPH_SIZE = 0x100000

R_CTRL, R_OBJ_BASE, R_OBJ_COUNT, R_ROOT_COUNT = 0x00, 0x04, 0x08, 0x0C
R_MARKED, R_CYCLES = 0x10, 0x14
R_STATUS, R_BM_ADDR, R_BM_DATA = 0x20, 0x24, 0x28
R_MAGIC, R_VERSION, R_ROOT_LIST = 0x30, 0x34, 0x40

CTRL_START, CTRL_CLEAR_Q, CTRL_ABORT, CTRL_DONE = 1, 4, 8, (1 << 31)
CTRL_WR_MARK = 0xA5000000   # command writes carry their destination in WDATA[31:20]
HDR_BASE = 0x0000
DELAYS_US = [3, 10, 25, 41, 50, 75, 120, 200, 300, 400, 480]

def task(pct, label):
    sys.stdout.write("@@TASK %d %s\n" % (pct, label)); sys.stdout.flush()

def main():
    argv = sys.argv[1:]
    seed = 20261019
    delays = DELAYS_US
    pos = []
    i = 0
    while i < len(argv):
        if argv[i] == '--seed':
            seed = int(argv[i + 1]); i += 2
        elif argv[i] == '--delays':
            delays = [int(x) for x in argv[i + 1].split(',')]; i += 2
        else:
            pos.append(argv[i]); i += 1
    n = int(pos[0]) if len(pos) > 0 else 4096
    avg_refs = int(pos[1]) if len(pos) > 1 else 2
    rng = random.Random(seed)
    L = (n * 3) // 4

    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=REG_BASE)
    gph  = mmap.mmap(fd, GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=GRAPH_BASE)

    def rr(o):    return struct.unpack_from('<I', regs, o)[0]
    def wr(o, v): struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)
    def gr(o):    return struct.unpack_from('<I', gph, o)[0]

    print("=" * 84)
    print(" FOGCCC  abort phase sweep   N=%d L=%d avg_refs=%d seed=%d" % (n, L, avg_refs, seed))
    print("   MAGIC=0x%08X VERSION=0x%08X" % (rr(R_MAGIC), rr(R_VERSION)))
    print("=" * 84)
    if rr(R_MAGIC) != 0x47434343:
        print("   FAIL: MAGIC mismatch"); return 1

    # ---- one graph, built once ----
    edges = [[] for _ in range(n)]
    for i in range(1, L):
        p = rng.randrange(0, i); edges[p].append(i); edges[i].append(p)
    for i in range(L):
        for _ in range(rng.randrange(0, avg_refs + 1)):
            x = rng.randrange(0, L)
            if x != i: edges[i].append(x)
    for i in range(L, n):
        for _ in range(rng.randrange(0, avg_refs * 2 + 1)):
            x = rng.randrange(L, n)
            if x != i: edges[i].append(x)
    rc = [len(e) for e in edges]
    REF_BASE = (HDR_BASE + n * 16 + 0xFFF) & ~0xFFF
    off, cur = [0] * n, REF_BASE
    for i in range(n):
        off[i] = cur; cur += rc[i] * 4 + 4
    buf = bytearray(cur)
    for i in range(n):
        struct.pack_into('<IIII', buf, HDR_BASE + i * 16, i, rc[i], GRAPH_BASE + off[i], 0)
    for i in range(n):
        for j, x in enumerate(edges[i]):
            struct.pack_into('<I', buf, off[i] + j * 4, x)
        struct.pack_into('<I', buf, off[i] + rc[i] * 4, 0xFFFFFFFF)
    gph[0:len(buf)] = bytes(buf)
    time.sleep(0.02)

    sw = bytearray(n); q = [0]; sw[0] = 1; head = 0
    while head < len(q):
        c = q[head]; head += 1
        c_rc = gr(HDR_BASE + c * 16 + 4); c_ro = gr(HDR_BASE + c * 16 + 8) - GRAPH_BASE
        for j in range(c_rc):
            x = gr(c_ro + j * 4)
            if x == 0xFFFFFFFF: break
            if x < n and not sw[x]: sw[x] = 1; q.append(x)
    sw_n = len(q)
    print("   graph: SW BFS = %d (expect L = %d)" % (sw_n, L))
    if sw_n != L:
        print("   FAIL: oracle mismatch"); return 1

    wr(R_ROOT_LIST, 0); wr(R_ROOT_COUNT, 1)
    wr(R_OBJ_BASE, GRAPH_BASE); wr(R_OBJ_COUNT, n)
    wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q); time.sleep(0.002)

    def wait_done(ms):
        end = time.time() + ms / 1000.0
        while time.time() < end:
            if rr(R_CTRL) & CTRL_DONE: return True
        return False

    def spin_us(us):
        t0 = time.perf_counter_ns(); target = t0 + us * 1000
        while time.perf_counter_ns() < target:
            pass

    def readback_ok():
        # Phase 2: wait for the free-list scanner to release the bitmap port.
        t0 = time.time()
        while (rr(R_STATUS) & 0x20) and (time.time() - t0) < 1.0:
            time.sleep(0.0002)
        bad = 0
        for obj in range(n):
            wr(R_BM_ADDR, obj); rr(R_BM_ADDR)
            hb = (rr(R_BM_DATA) >> (obj & 31)) & 1
            if hb != sw[obj]:
                bad += 1
                if bad <= 2: print("      bitmap mismatch obj %d hw=%d sw=%d" % (obj, hb, sw[obj]))
        return bad

    fails = []
    rows = []
    for k, d in enumerate(delays):
        task(int(5 + 85.0 * k / len(delays)), "phase %d/%d (%d us)" % (k + 1, len(delays), d))
        wr(R_CTRL, CTRL_WR_MARK | CTRL_START)
        spin_us(d)
        st_pre  = (rr(R_STATUS) & 0xF)
        done_pre = bool(rr(R_CTRL) & CTRL_DONE)
        wr(R_CTRL, CTRL_WR_MARK | CTRL_ABORT)
        st_post = (rr(R_STATUS) & 0xF)
        done_after = False
        t0 = time.time()
        while time.time() - t0 < 0.020:
            if rr(R_CTRL) & CTRL_DONE:
                done_after = True; break
        # recovery
        wr(R_CTRL, CTRL_WR_MARK | CTRL_START)
        ok = wait_done(300)
        mkd = rr(R_MARKED); st_rec = (rr(R_STATUS) & 0xF)
        bad = readback_ok() if ok else -1
        row = dict(d=d, skip=done_pre, stop=(not done_after), st_pre=st_pre,
                   st_post=st_post, ok=ok, mkd=mkd, st_rec=st_rec, bad=bad)
        rows.append(row)
        print("   %4d us: already_done=%s stopped=%s status(pre/post)=0x%X/0x%X -> rec done=%s marked=%d status=0x%X bitmap_bad=%s"
              % (d, done_pre, not done_after, st_pre, st_post, ok, mkd, st_rec, bad))
        if not done_pre and done_after:
            fails.append("%d us: DONE set after abort" % d)
        if not ok:      fails.append("%d us: recovery no DONE" % d)
        if mkd != L:    fails.append("%d us: recovery marked=%d != %d" % (d, mkd, L))
        if st_rec != 0: fails.append("%d us: recovery status=0x%X" % (d, st_rec))
        if bad:         fails.append("%d us: bitmap %d bad" % (d, bad))
        time.sleep(0.005)

    task(96, "summarising")
    print()
    print("=" * 84)
    print(" SUMMARY   %d phases; abort statuses (observation only):" % len(rows))
    print("   " + " ".join("%dus=0x%X" % (r['d'], r['st_post']) for r in rows))
    skipped = sum(1 for r in rows if r['skip'])
    print("   skipped (run already finished before the abort): %d" % skipped)
    for f in fails:
        print("   FAIL: " + f)
    if fails:
        print("   RESULT: FAIL (%d)" % len(fails)); return 1
    print("   RESULT: PASS (%d/%d phases stopped and recovered exactly)" % (len(rows) - skipped, len(rows)))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
