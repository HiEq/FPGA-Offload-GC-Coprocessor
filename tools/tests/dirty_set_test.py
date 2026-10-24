#!/usr/bin/env python3
# ============================================================
# dirty_set_test.py - Phase 3A board test: the barrier dirty set as a work source
#
# A (directed)  : no roots, dirty = {0,40,41} -> marks {0,1,2,3,40,41} exactly;
#                 pushed/occ must agree and lie in [3,6) (this board's write path
#                 redelivers a store twice, not always adjacently, so one logical
#                 push can enqueue two records of the SAME id -- the mark set
#                 stays exact, only the count is inflated; see README 3A/3B);
#                 the free list must be the other 58 ids.  A0 is the negative
#                 control: the same run without any dirty push marks nothing.
# B (directed)  : BM_KEEP + obj0 gained ref 10, dirty = {0} -> the already
#                 marked container is re-scanned (a dedup would leave obj10
#                 unmarked); the epoch count is 1, the cumulative bitmap 7.
# C (directed)  : 300 pushes into a 256-deep FIFO latch the overflow flag;
#                 a DIRTY_FLUSH applied by a full-mark start clears it.
# D (real graph): interpreter container graph, epoch 1 = full mark; then a
#                 mutator adds edges from live containers to garbage objects
#                 and records those containers; epoch 2 = BM_KEEP + roots=0 +
#                 dirty = the recorded containers.  The bitmap must equal the
#                 CPU oracle, drained must equal pushed (both >= len(dirty) and
#                 < 2*len(dirty)) and the free list must be the never-marked set.
# D-neg         : the same two epochs but WITHOUT the dirty pushes -> the new
#                 targets must stay unmarked (the barrier-missing control:
#                 the test fails if the hardware marks them anyway).
#
# CTRL[5] = DIRTY_FLUSH is ARMED by the write and applied by the next accepted
# START with BM_KEEP=0 while the engine is idle; an incremental start DISCARDS
# it (arm-and-consume).  Clearing the FIFO now is therefore arm + full-mark
# start + wait, i.e. dirty_flush_now() below -- a bare write only arms.
#
# usage: python3 dirty_set_test.py   (needs root, /dev/mem; PL = the v4.2 build)
# exit 0 = all checks pass
# ============================================================
import mmap
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import side_table_test as C

R_CTRL = 0x00
R_BASE = 0x04
R_COUNT = 0x08
R_ROOTS = 0x0C
R_MARKED = 0x10
R_STATUS = 0x20
R_BMADDR = 0x24
R_BMDATA = 0x28
R_MAGIC, R_VERSION = 0x30, 0x34
R_FCOUNT = 0x38
R_FDATA = 0x3C
R_DPUSH = 0x440
R_DSTAT = 0x444
R_DDRAIN = 0x448
R_DPUSHED = 0x44C
R_DPOPPED = 0x450
R_RLIST = 0x40

CTRL_START, CTRL_CLEAR_Q, CTRL_DONE = 1, 4, (1 << 31)
CTRL_BM_KEEP, CTRL_DIRTY_FLUSH = (1 << 4), (1 << 5)
CTRL_WR_MARK = 0xA5000000   # command writes carry their destination in WDATA[31:20]
PUSH_WR_MARK = 0xA5400000
STATUS_FREEBUSY = 1 << 5
BASE = C.GRAPH_BASE

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.REG_BASE)
gph = mmap.mmap(fd, C.GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.GRAPH_BASE)
rr = lambda o: struct.unpack_from('<I', regs, o)[0]
wr = lambda o, v: struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)
gw = lambda o, v: struct.pack_into('<I', gph, o, v & 0xFFFFFFFF)
gr = lambda o: struct.unpack_from('<I', gph, o)[0]

fails = []

# DIRTY_PUSH is a command-with-tag: this board's AXI-Lite write path delivers
# every store twice, so the tag must CHANGE for each logical push.  Seed the
# sequence from the hardware's last accepted tag.
_push_tag = None


def push(oid):
    global _push_tag
    if _push_tag is None:
        _push_tag = (rr(R_DSTAT) >> 16) & 0xF
    _push_tag = (_push_tag + 1) & 0xF
    wr(R_DPUSH, PUSH_WR_MARK | (_push_tag << 12) | (oid & 0xFFF))


def push_acked(oid):
    """push() + id-level ack (AGENTS #20): retry with a fresh tag until 0x444
    reports this exact (tag,id).  Used where the record count must be exact; the
    overflow segment keeps the plain push (there a dropped record is the point)."""
    for _ in range(5):
        push(oid)
        for _ in range(8):
            st = rr(R_DSTAT)
            if (st >> 9) & 1:                       # sticky overflow
                return False
            if ((st >> 16) & 0xF) == _push_tag and ((st >> 20) & 0xFFF) == (oid & 0xFFF):
                return True
    return False


def wait_done_and_idle(timeout=5.0):
    t0 = time.time()
    while time.time() < t0 + timeout:
        if rr(R_CTRL) & CTRL_DONE:
            break
        time.sleep(0.0002)
    t0 = time.time()
    while time.time() < t0 + timeout:
        if (rr(R_STATUS) & STATUS_FREEBUSY) == 0:
            break
        time.sleep(0.0002)
    return (rr(R_CTRL) & CTRL_DONE) != 0


def start_epoch(keep):
    wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q)
    time.sleep(0.002)
    wr(R_CTRL, CTRL_WR_MARK | CTRL_START | (CTRL_BM_KEEP if keep else 0))
    _ = rr(R_CTRL)


def dirty_flush_now():
    """Clear the dirty FIFO now (arm-and-consume: CTRL[5] is only armed by the
    write; the engine applies it at the next accepted full-mark START).  Arm +
    full-mark start + wait; returns True when DONE was seen."""
    wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q | CTRL_DIRTY_FLUSH)
    start_epoch(False)
    return wait_done_and_idle()


def read_marks(n):
    """bitmap probe -> list of marked flags"""
    out = []
    for o in range(n):
        wr(R_BMADDR, o)
        _ = rr(R_BMADDR)
        out.append((rr(R_BMDATA) >> (o & 31)) & 1)
    return out


def main():
    if rr(R_MAGIC) != 0x47434343 or rr(R_VERSION) != 0x00040300:
        print('FAIL magic/version 0x%08X/0x%08X (need the v4.2 bitstream)'
              % (rr(R_MAGIC), rr(R_VERSION)))
        return 1
    print('magic/version OK: 0x%08X / 0x00040300' % rr(R_MAGIC))

    n = 64
    wr(R_BASE, BASE)                    # 0x04: reset value is 0, never inherit it
    # obj0 -> {1,2,3}; everything else ref_count 0
    for i in range(n):
        gw(i * 16 + 0, i)
        gw(i * 16 + 4, 3 if i == 0 else 0)
        gw(i * 16 + 8, BASE + 0x1000)
    for i in range(3):
        gw(0x1000 + i * 4, i + 1)
    gw(0x1000 + 12, 0xFFFFFFFF)
    wr(R_COUNT, n)
    wr(R_ROOTS, 0)

    # ---- A0: negative control (no barrier) ----
    ok = dirty_flush_now()
    a0_marked, a0_drain = rr(R_MARKED), rr(R_DDRAIN)
    print('A0 no-barrier: done=%s marked=%d drained=%d (expect 0/0)' % (ok, a0_marked, a0_drain))
    if a0_marked != 0 or a0_drain != 0:
        fails.append('A0')

    # ---- A: dirty-driven, no roots ----
    # A0 left the FIFO clean and the bitmap clear; a flush write here would be
    # applied by this epoch's own start (arm-and-consume) and drop the records.
    for i in (0, 40, 41):
        push_acked(i)          # exact: a cold-window loss would break the 6/58 check
    occ, pushed = rr(R_DSTAT) & 0x1FF, rr(R_DPUSHED)
    start_epoch(False)
    ok = wait_done_and_idle()
    a_marked, a_drain, a_pop = rr(R_MARKED), rr(R_DDRAIN), rr(R_DPOPPED)
    fc = rr(R_FCOUNT)
    ids = [rr(R_FDATA) & 0xFFF for _ in range(fc)]
    fset = set(ids)
    exp_marked = {0, 1, 2, 3, 40, 41}
    # This board's AXI-Lite write path delivers a store twice and the two copies
    # are not always adjacent, so one logical push can enqueue two records of the
    # same id (measured: a single store sometimes gives occ=2).  The counts stay
    # bounded (>= logical, < 2x logical) and must agree with each other; marked
    # and the free list stay exact, because the extra record is a duplicate of an
    # id that is already in the set.  See README, Phase 3A/3B.
    print('A dirty-run: occ=%d pushed=%d | marked=%d drained=%d popped=%d free=%d'
          ' (expect pushed==occ in [3,6), drained==popped==pushed, marked=6 free=58)'
          % (occ, pushed, a_marked, a_drain, a_pop, fc))
    if not (3 <= pushed < 6) or occ != pushed or not (a_drain == a_pop == pushed):
        fails.append('A')
    if (a_marked, fc) != (6, 58):
        print('A FAIL: marked=%d free=%d (expected 6 / 58)' % (a_marked, fc))
        fails.append('A-count')
    if fset & exp_marked:
        print('A FAIL: the free list contains marked ids %s' % sorted(fset & exp_marked))
        fails.append('A-free')

    # ---- B: BM_KEEP + forced re-scan of an already marked container ----
    gw(0 * 16 + 4, 4)                      # obj0 -> {1,2,3,10}
    for i, v in enumerate((1, 2, 3, 10)):
        gw(0x1000 + i * 4, v)
    gw(0x1000 + 16, 0xFFFFFFFF)
    # No flush: this epoch must KEEP A's bitmap (that is what makes obj0 a
    # re-scan), and a BM_KEEP start discards an armed flush anyway.
    push_acked(0)                           # already marked -> must be re-scanned
    start_epoch(True)                      # BM_KEEP
    ok = wait_done_and_idle()
    b_epoch = rr(R_MARKED)
    marks = read_marks(n)
    got = {i for i in range(n) if marks[i]}
    exp = {0, 1, 2, 3, 10, 40, 41}
    print('B keep+rescan: epoch_marked=%d cumulative=%s (expect 1 / %s)'
          % (b_epoch, sorted(got), sorted(exp)))
    if b_epoch != 1 or got != exp:
        print('B FAIL: forced re-scan of an already marked container')
        fails.append('B')

    # ---- C: overflow flag ----
    # B's epoch drained its own record, so the FIFO is empty here.
    for i in range(300):
        push(i % n)
    st = rr(R_DSTAT)
    print('C overflow: occupancy=%d ovf=%d pending=%d (expect 256/1/1)'
          % (st & 0x1FF, (st >> 9) & 1, (st >> 10) & 1))
    if (st & 0x1FF) != 256 or ((st >> 9) & 1) != 1:
        fails.append('C')
    dirty_flush_now()
    st = rr(R_DSTAT)
    if (st & 0x1FF) != 0 or ((st >> 9) & 1) != 0:
        print('C FAIL: flush did not clear (occ=%d ovf=%d)' % (st & 0x1FF, (st >> 9) & 1))
        fails.append('C-clear')

    # ---- D: real interpreter graph, two epochs (D-neg = the barrier-missing control) ----
    N, SEED = 512, 12345
    g = C.build_container_graph(N, SEED)
    live = set(i for i in range(N) if C.bfs_marked(g['refs'], g['root'])[i])
    garbage = [i for i in range(N) if i not in live]

    def build_img(edges):
        """write a graph image from an edge list (dict id -> [ids])"""
        ref_base = (N * 16 + 0xFFF) & ~0xFFF
        offs, cur = [0] * N, ref_base
        for i in range(N):
            offs[i] = cur
            cur += len(edges[i]) * 4 + 4
        buf = bytearray(cur)
        for i in range(N):
            struct.pack_into('<IIII', buf, i * 16, i, len(edges[i]), BASE + offs[i], 0)
        for i in range(N):
            for j, x in enumerate(edges[i]):
                struct.pack_into('<I', buf, offs[i] + j * 4, x)
            struct.pack_into('<I', buf, offs[i] + len(edges[i]) * 4, 0xFFFFFFFF)
        gph[0:len(buf)] = bytes(buf)

    def closure(edges, seeds):
        seen = set(seeds)
        stack = list(seeds)
        while stack:
            c = stack.pop()
            for x in edges[c]:
                if x not in seen:
                    seen.add(x)
                    stack.append(x)
        return seen

    def run_two_epochs(with_dirty):
        """epoch1 full mark; mutator adds edges; epoch2 BM_KEEP + dirty"""
        edges0 = [list(r) for r in g['refs']]
        build_img(edges0)
        wr(R_COUNT, N)
        wr(R_ROOTS, 1)
        wr(R_RLIST, g['root'])
        wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q | CTRL_DIRTY_FLUSH)
        start_epoch(False)
        wait_done_and_idle()
        e1 = rr(R_MARKED)
        # mutator: 3 live containers gain an edge to a garbage object
        dirty = [c for c in sorted(live) if c % 64 == 5][:3]
        edges1 = [list(r) for r in edges0]
        targets = garbage[:3]
        for c, t in zip(dirty, targets):
            edges1[c].append(t)
        build_img(edges1)
        wr(R_ROOTS, 0)
        # No flush here: the records pushed below must survive this epoch, and a
        # BM_KEEP start (the next step) discards an armed flush anyway.
        if with_dirty:
            for c in dirty:
                push_acked(c)
        start_epoch(True)
        wait_done_and_idle()
        e2 = rr(R_MARKED)
        drain, pushed_c = rr(R_DDRAIN), rr(R_DPUSHED)
        marks = read_marks(N)
        marked = {i for i in range(N) if marks[i]}
        fc = rr(R_FCOUNT)
        fids = set(rr(R_FDATA) & 0xFFF for _ in range(fc))
        return e1, e2, drain, pushed_c, marked, dirty, set(targets), fids

    live_seed = closure([list(r) for r in g['refs']], [g['root']])
    e1, e2, drain, pushed_c, marked, dirty, targets, fids = run_two_epochs(True)
    edges1 = [list(r) for r in g['refs']]
    for c, t in zip(dirty, targets):
        edges1[c].append(t)
    oracle = closure(edges1, live_seed | set(dirty))
    print('D real graph: e1=%d e2=%d drained=%d pushed=%d | marked=%d oracle=%d dirty=%s targets=%s'
          % (e1, e2, drain, pushed_c, len(marked), len(oracle), dirty, sorted(targets)))
    if e1 != len(live_seed):
        print('D FAIL: epoch1 marked %d != live %d' % (e1, len(live_seed)))
        fails.append('D-e1')
    if not targets <= marked:
        print('D FAIL: new targets not marked by the dirty epoch')
        fails.append('D-targets')
    if marked != oracle:
        print('D FAIL: marked != oracle (missing %s extra %s)'
              % (sorted(oracle - marked)[:8], sorted(marked - oracle)[:8]))
        fails.append('D-oracle')
    if drain != pushed_c or not (len(dirty) <= pushed_c < 2 * len(dirty)):
        print('D FAIL: drained=%d pushed=%d dirty=%d (counts must agree, in [dirty, 2*dirty))'
              % (drain, pushed_c, len(dirty)))
        fails.append('D-drain')
    if fids != set(range(N)) - oracle:
        print('D FAIL: free list != never-marked set')
        fails.append('D-free')

    # D-neg: same scenario without the barrier -> the targets must stay unmarked
    e1n, e2n, drainn, pushedn, markedn, dirtyn, targetsn, _ = run_two_epochs(False)
    missed = sorted(t for t in targetsn if t not in markedn)
    print('D-neg no-barrier: drained=%d pushed=%d targets_unmarked=%s (must be non-empty)'
          % (drainn, pushedn, missed))
    if not missed:
        print('D-neg FAIL: without the barrier the new targets were marked anyway')
        fails.append('D-neg')

    print('DIRTY_SET_RESULT %s' % ('OK' if not fails else 'FAIL:' + ','.join(fails)))
    regs.close()
    gph.close()
    os.close(fd)
    print('DIAG_DONE')
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.exit(main())