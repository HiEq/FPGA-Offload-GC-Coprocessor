#!/usr/bin/env python3
# ============================================================
# ctrl_spill_test.py - a spilled CTRL store must not corrupt a running epoch
#
# This board redelivers every AXI-Lite store and the copies are not always
# adjacent, so a driver write of `CTRL = CLEAR_Q` can arrive again while the
# engine is mid-run.  The gated build honours the software clear only while the
# engine is idle (gc_top) and the engine clears the object queue itself when it
# accepts a START (gc_mark_engine); the invariant that makes it observable is
# `q_tail == marked`.
#   ungated build (bit md5 529594D7…, sim T-CTRL-SPILL): the spilled clear resets
#   the queue pointer mid-run (q_tail < marked) and a spilled START re-runs the
#   graph on top of the old tail (q_tail = 2 * marked).
#
# usage: python3 ctrl_spill_test.py    (root, /dev/mem, PL = the spill build)
# ============================================================
import mmap
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import side_table_test as C

R_CTRL, R_BASE, R_COUNT, R_ROOTS, R_MARKED = 0x00, 0x04, 0x08, 0x0C, 0x10
R_QHEAD, R_QTAIL, R_STATUS = 0x18, 0x1C, 0x20
R_RLIST = 0x40
CTRL_START, CTRL_CLEAR_Q, CTRL_DIRTY_FLUSH, CTRL_DONE = 1, 4, (1 << 5), (1 << 31)
CTRL_WR_MARK = 0xA5000000   # command writes carry their destination in WDATA[31:20]
STATUS_IDLE = 1 << 4
BASE = C.GRAPH_BASE
N = 3000                     # root -> 1..N-1: long enough to place the spill mid-run
REFS_OFF = 0x20000            # past N*16 (3000 objs = 0xBB80), inside the 1 MB graph
REFS = BASE + REFS_OFF

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.REG_BASE)
gph = mmap.mmap(fd, C.GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.GRAPH_BASE)
rr = lambda o: struct.unpack_from('<I', regs, o)[0]
wr = lambda o, v: struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)
gw = lambda o, v: struct.pack_into('<I', gph, o, v & 0xFFFFFFFF)

fails = []


def wait_done(timeout=20.0):
    t0 = time.time()
    while time.time() < t0 + timeout:
        if rr(R_CTRL) & CTRL_DONE:
            break
        time.sleep(0.00005)
    return (rr(R_CTRL) & CTRL_DONE) != 0


def main():
    if rr(0x30) != 0x47434343 or rr(0x34) != 0x00040300:
        print('FAIL magic/version 0x%08X/0x%08X (need v4.2 with spill protection)'
              % (rr(0x30), rr(0x34)))
        return 1
    print('magic/version OK: 0x%08X / 0x00040300' % rr(0x30))

    # a fan: obj0 -> 1..199, every other object has no refs
    for i in range(N):
        gw(i * 16 + 0, i)
        gw(i * 16 + 4, (N - 1) if i == 0 else 0)
        gw(i * 16 + 8, REFS)
    for i in range(N - 1):
        gw(REFS_OFF + i * 4, i + 1)
    gw(REFS_OFF + (N - 1) * 4, 0xFFFFFFFF)          # terminator slot

    wr(R_BASE, BASE)
    wr(R_COUNT, N)
    wr(R_ROOTS, 1)
    wr(R_RLIST, 0)
    wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q | CTRL_DIRTY_FLUSH)
    time.sleep(0.002)

    # ---- run 1: spill a CLEAR_Q while the engine is mid-run --------------------
    # The write only proves anything if the engine is still running when it lands:
    # after DONE a CLEAR_Q is a legal idle clear.  Retry the run until a spill
    # actually lands while busy; a missed window is not a test failure.
    m1 = t1 = None
    attempts = 0
    for attempts in range(1, 6):
        wr(R_CTRL, CTRL_WR_MARK | CTRL_START)
        # DONE is sticky from the previous run until this START is accepted.
        t0 = time.time()
        while (rr(R_CTRL) & CTRL_DONE) and time.time() - t0 < 0.01:
            pass
        busy = False
        for _ in range(20000):
            if rr(R_CTRL) & CTRL_DONE:
                break
            if (rr(R_QHEAD) & 0xFFF) != (rr(R_QTAIL) & 0xFFF):
                busy = True
                break
        if not busy:
            continue
        wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q)                   # the spilled store
        if rr(R_STATUS) & STATUS_IDLE:             # finished before it landed
            continue
        if not wait_done():
            print('FAIL run 1: DONE never asserted')
            return 1
        m1, t1 = rr(R_MARKED), rr(R_QTAIL) & 0xFFF
        break
    if m1 is None:
        print('FAIL run 1: could not place CLEAR_Q while the engine was busy')
        return 1
    print('run 1 spilled CLEAR_Q: marked=%d q_tail=%d (expect %d / %d, attempt %d)'
          % (m1, t1, N, N, attempts))
    if m1 != N:
        print('FAIL run 1: marked=%d != %d' % (m1, N))
        fails.append('m1')
    if t1 != m1:
        print('FAIL run 1: q_tail=%d != marked=%d (the spilled clear reset the queue)' % (t1, m1))
        fails.append('t1')

    # ---- run 2: spill a START (no clear): a re-run must not inherit the tail ----
    wr(R_CTRL, CTRL_WR_MARK | CTRL_START)
    if not wait_done():
        print('FAIL run 2: DONE never asserted')
        return 1
    m2, t2 = rr(R_MARKED), rr(R_QTAIL) & 0xFFF
    print('run 2 spilled START  : marked=%d q_tail=%d (expect %d / %d)' % (m2, t2, N, N))
    if m2 != N:
        print('FAIL run 2: marked=%d != %d' % (m2, N))
        fails.append('m2')
    if t2 != m2:
        print('FAIL run 2: q_tail=%d != marked=%d (the re-run inherited the old tail: %d)'
              % (t2, m2, 2 * N))
        fails.append('t2')

    st = rr(R_STATUS)
    if st & 0x0F:
        print('FAIL: STATUS error bits 0x%X' % st)
        fails.append('status')

    print('CTRL_SPILL_RESULT %s' % ('OK' if not fails else 'FAIL:' + ','.join(fails)))
    wr(R_CTRL, CTRL_WR_MARK | CTRL_DIRTY_FLUSH)                   # arm; the next full-mark start clears the FIFO
    regs.close()
    gph.close()
    os.close(fd)
    print('DIAG_DONE')
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.exit(main())