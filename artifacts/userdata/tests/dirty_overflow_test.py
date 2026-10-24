#!/usr/bin/env python3
# ============================================================
# dirty_overflow_test.py - Phase 3A overflow contract, saturated WHILE the engine
# runs, plus the full-mark fallback
#
# Contract (see README, Phase 3A/3B):
#   * the FIFO is 256 deep; a push while full is DROPPED and the sticky overflow
#     bit `DIRTY_STAT[9]` is latched -- never a silent loss;
#   * the software that sees the flag must fall back to a full mark, because the
#     dropped records are gone for that epoch.
#
# Sequence:
#   epoch 1  full mark on the interpreter graph                 -> live
#   epoch 2  incremental epoch kept busy by a hot-container seed; the main
#            thread then pushes far more than 256 barrier records while the
#            engine runs -> the FIFO accepts 256 and latches overflow for the
#            rest (the engine is sampled so the burst is provably concurrent)
#   control  ignoring the flag and continuing incrementally -> the dropped
#            containers' targets stay unmarked (this must FAIL the oracle;
#            that is why the fallback is mandatory)
#   contract bm_keep=0 + CTRL[5] (full mark) -> marked == closure(final, roots),
#            free list == the complement, STATUS clean, overflow cleared
#
# usage: python3 dirty_overflow_test.py   (root, /dev/mem, PL = v4.2)
# ============================================================
import mmap
import os
import random
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import side_table_test as C

R_CTRL, R_COUNT, R_ROOTS, R_MARKED, R_STATUS = 0x00, 0x08, 0x0C, 0x10, 0x20
R_BASE = 0x04
R_BMADDR, R_BMDATA = 0x24, 0x28
R_FCOUNT, R_FDATA = 0x38, 0x3C
R_DPUSH, R_DSTAT, R_DDRAIN, R_DPUSHED, R_DPOPPED = 0x440, 0x444, 0x448, 0x44C, 0x450
R_RLIST = 0x40

CTRL_START, CTRL_CLEAR_Q, CTRL_DONE = 1, 4, (1 << 31)
CTRL_BM_KEEP, CTRL_DIRTY_FLUSH = (1 << 4), (1 << 5)
STATUS_FREEBUSY, STATUS_ERR = (1 << 5), 0x0F
DSTAT_OVF, DSTAT_COUNT = (1 << 9), 0x1FF
BASE = C.GRAPH_BASE
SEED_PUSHES = 30        # hot-container records that keep the epoch busy
BURST = 400             # logical barrier pushes in the burst (> 256 on purpose)
HEAVY_REFS = 1024

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.REG_BASE)
gph = mmap.mmap(fd, C.GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.GRAPH_BASE)
rr = lambda o: struct.unpack_from('<I', regs, o)[0]
wr = lambda o, v: struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)

fails = []
tag = [None]


def push(oid):
    """command-with-tag DIRTY_PUSH: the tag must change per logical push"""
    if tag[0] is None:
        tag[0] = (rr(R_DSTAT) >> 16) & 0xF
    tag[0] = (tag[0] + 1) & 0xF
    wr(R_DPUSH, (tag[0] << 12) | (oid & 0xFFF))


def wait_done_and_idle(timeout=30.0):
    t0 = time.time()
    while time.time() < t0 + timeout:
        if rr(R_CTRL) & CTRL_DONE:
            break
        time.sleep(0.00005)
    t0 = time.time()
    while time.time() < t0 + timeout:
        if (rr(R_STATUS) & STATUS_FREEBUSY) == 0:
            break
        time.sleep(0.0001)
    return (rr(R_CTRL) & CTRL_DONE) != 0


def start_epoch(keep):
    wr(R_CTRL, CTRL_CLEAR_Q)
    time.sleep(0.002)
    wr(R_CTRL, CTRL_START | (CTRL_BM_KEEP if keep else 0))
    _ = rr(R_CTRL)


def read_marks(n):
    out = []
    for o in range(n):
        wr(R_BMADDR, o)
        _ = rr(R_BMADDR)
        out.append((rr(R_BMDATA) >> (o & 31)) & 1)
    return out


def main():
    if rr(0x30) != 0x47434343 or rr(0x34) != 0x00040200:
        print('FAIL magic/version 0x%08X/0x%08X (need v4.2)' % (rr(0x30), rr(0x34)))
        return 1
    print('magic/version OK: 0x%08X / 0x00040200' % rr(0x30))

    N, SEEDG = 1024, 12345
    g = C.build_container_graph(N, SEEDG)
    root = g['root']
    live = set(i for i in range(N) if C.bfs_marked(g['refs'], g['root'])[i])
    live_l = sorted(live)
    garbage = [i for i in range(N) if i not in live]
    ref_base = (N * 16 + 0xFFF) & ~0xFFF
    edges = [list(r) + [0xFFFFFFFF] for r in g['refs']]
    offs = [0] * N

    HEAVY = live_l[-1]
    hidx = edges[HEAVY].index(0xFFFFFFFF)
    edges[HEAVY] = edges[HEAVY][:hidx] + [HEAVY] * HEAVY_REFS + [0xFFFFFFFF]

    def build_offsets(e):
        cur = ref_base
        for i in range(N):
            offs[i] = cur
            cur += len(e[i]) * 4 + 4
        return cur

    def write_image(e):
        total = build_offsets(e)
        buf = bytearray(total)
        for i in range(N):
            struct.pack_into('<IIII', buf, i * 16, i, len(e[i]), BASE + offs[i], 0)
        for i in range(N):
            for j, x in enumerate(e[i]):
                struct.pack_into('<I', buf, offs[i] + j * 4, x)
        gph[0:len(buf)] = bytes(buf)

    def closure(seeds):
        seen, stack = set(seeds), list(seeds)
        while stack:
            c = stack.pop()
            for x in edges[c]:
                if x != 0xFFFFFFFF and x not in seen and x < N:
                    seen.add(x)
                    stack.append(x)
        return seen

    print('graph: n=%d live=%d garbage=%d heavy=%d burst=%d' % (N, len(live), len(garbage), HEAVY, BURST))

    # ---- epoch 1: full mark -------------------------------------------------
    edges[:] = [list(r) + [0xFFFFFFFF] for r in g['refs']]
    edges[HEAVY] = edges[HEAVY][:hidx] + [HEAVY] * HEAVY_REFS + [0xFFFFFFFF]
    write_image(edges)
    wr(R_COUNT, N)
    wr(R_ROOTS, 1)
    wr(R_RLIST, root)
    wr(R_BASE, BASE)                      # 0x04: reset value is 0, never inherit it
    wr(R_CTRL, CTRL_CLEAR_Q | CTRL_DIRTY_FLUSH)
    start_epoch(False)
    wait_done_and_idle()
    e1 = rr(R_MARKED)
    print('epoch 1 full mark: marked=%d (expect %d)' % (e1, len(live)))
    if e1 != len(live):
        fails.append('e1')
    wr(R_ROOTS, 0)

    # ---- the mutator: write edges, push a barrier record per written container
    #      (more than the FIFO can hold, on purpose) ---------------------------
    rng = random.Random(SEEDG + 7)
    pool = [i for i in live_l if i != HEAVY]
    rng.shuffle(pool)
    written = pool[:BURST]
    # The first 256 pushes are the ones the FIFO accepts, so make THOSE writes
    # add nothing new (targets that are already live) and let the containers that
    # will be DROPPED point at distinct garbage objects -- otherwise the control
    # below cannot show a missing mark.
    targets = [live_l[k % len(live_l)] if k < 256 else garbage[(k - 256) % len(garbage)]
               for k in range(len(written))]
    for c, t in zip(written, targets):
        struct.pack_into('<I', gph, offs[c] + (len(edges[c]) - 1) * 4, t)
        struct.pack_into('<I', gph, offs[c] + len(edges[c]) * 4, 0xFFFFFFFF)
        edges[c].insert(len(edges[c]) - 1, t)
        _ = struct.unpack_from('<I', gph, offs[c])[0]      # fence: visible first

    # ---- epoch 2: incremental, hot-container seed, then a saturating burst ---
    # No flush here: CTRL[5] is only ARMED by the write and applied by a
    # BM_KEEP=0 start, which this epoch must not use -- it has to keep epoch 1's
    # bitmap.  The dirty counters are already at 0 (epoch 1 is a root full mark,
    # which pushes no dirty records, and the flush above reset them).
    for _ in range(SEED_PUSHES):
        push(HEAVY)
    start_epoch(True)
    live_samples = 0
    for i, c in enumerate(written):
        push(c)
        if (i & 15) == 0:
            _ = rr(R_CTRL)                                    # keep it posted-ordered
            if ((rr(R_STATUS) >> 4) & 1) == 0:
                live_samples += 1                             # engine was out of S_IDLE
    done = wait_done_and_idle()
    occ, ovf = rr(R_DSTAT) & DSTAT_COUNT, (rr(R_DSTAT) >> 9) & 1
    pushed, popped, drained = rr(R_DPUSHED) & 0xFFFF, rr(R_DPOPPED) & 0xFFFF, rr(R_DDRAIN)
    print('epoch 2 burst: done=%s live_samples=%d | occ=%d ovf=%d | pushed=%d popped=%d drained=%d'
          % (done, live_samples, occ, ovf, pushed, popped, drained))
    print('               logical pushes=%d (seed %d + burst %d) -> accepted %d, dropped %d'
          % (SEED_PUSHES + BURST, SEED_PUSHES, BURST, pushed, SEED_PUSHES + BURST - pushed))
    oracle = closure(live | set(written))
    if not done:
        fails.append('e2-timeout')
    if live_samples == 0:
        fails.append('noc')
    if ovf != 1 or pushed < 256:
        print('FAIL: the FIFO must saturate and latch overflow (ovf=%d pushed=%d)' % (ovf, pushed))
        fails.append('ovf')

    # ---- control: ignore the flag, keep going incrementally ------------------
    start_epoch(True)                     # bm_keep, no flush: only the accepted set
    wait_done_and_idle()
    marks = read_marks(N)
    marked = {i for i in range(N) if marks[i]}
    missed = sorted(oracle - marked)
    print('control (flag ignored, incremental): marked=%d oracle=%d missed=%d'
          % (len(marked), len(oracle), len(missed)))
    if not missed:
        print('CONTROL FAIL: ignoring the overflow flag still produced the exact set'
              ' -- the test cannot show why the fallback is mandatory')
        fails.append('control')
    if len(marked - oracle):
        print('CONTROL FAIL: extra marks %s' % sorted(marked - oracle)[:6])
        fails.append('control-extra')

    # ---- contract: the fallback full mark must recover the exact set ---------
    wr(R_ROOTS, 1)                        # the fallback re-establishes the root set
    wr(R_RLIST, root)
    wr(R_CTRL, CTRL_CLEAR_Q | CTRL_DIRTY_FLUSH)
    start_epoch(False)
    wait_done_and_idle()
    fb = rr(R_MARKED)
    marks = read_marks(N)
    marked = {i for i in range(N) if marks[i]}
    fc = rr(R_FCOUNT)
    fids = set(rr(R_FDATA) & 0xFFF for _ in range(fc))
    after = rr(R_DSTAT)
    st = rr(R_STATUS)
    print('fallback full mark: marked=%d oracle=%d | free=%d expect=%d | STATUS=0x%X ovf=%d'
          % (len(marked), len(oracle), len(fids), N - len(oracle), st, (after >> 9) & 1))
    if marked != oracle:
        print('FAIL: fallback marked != oracle (missing %s extra %s)'
              % (sorted(oracle - marked)[:6], sorted(marked - oracle)[:6]))
        fails.append('fallback')
    if fids != set(range(N)) - oracle:
        print('FAIL: free list != never-marked set')
        fails.append('free')
    if st & STATUS_ERR:
        print('FAIL: STATUS error bits 0x%X' % st)
        fails.append('status')
    if (after >> 9) & 1 or (after & DSTAT_COUNT):
        print('FAIL: flush did not clear the overflow/FIFO (0x%08X)' % after)
        fails.append('clear')

    print('DIRTY_OVERFLOW_RESULT %s' % ('OK' if not fails else 'FAIL:' + ','.join(fails)))
    wr(R_CTRL, CTRL_DIRTY_FLUSH)          # arm; the next full-mark start clears the FIFO
    regs.close()
    gph.close()
    os.close(fd)
    print('DIAG_DONE')
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.exit(main())