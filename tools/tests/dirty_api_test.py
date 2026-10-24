#!/usr/bin/env python3
# ============================================================
# dirty_api_test.py - exercises the Phase 3A dirty-set API through the C driver and
# the Python binding (python/fogccc.py + py/libfogccc.so on the card)
#
#   python3 dirty_api_test.py        -> DIRTY_API_RESULT OK
#   python3 dirty_api_test.py --neg  -> DIRTY_API_RESULT FAIL  (the negative control
#        this test must catch: DIRTY_PUSH is written straight to 0x440 with a
#        CONSTANT tag, so after the first push the hardware ignores every record and
#        the incremental epoch misses the pushed container's closure)
#
# Checks
#   1. full mark                    -> marked == the C BFS oracle; bitmap == live set
#   2. incremental epoch (roots=0, NO flush) with two pushes: one already-marked
#      live container and one *unmarked* container -> the epoch marks exactly
#      closure(live, pushed) - live, the bitmap becomes the full oracle set, and
#      pushed == popped == drained (the counters the driver exposes)
#   3. 300 pushes with the engine idle saturate the 256-deep FIFO: the sticky
#      overflow bit latches with pushed == 256, and dirty_flush() clears it
#
# usage: python3 dirty_api_test.py [-n 512]
# ============================================================
import ctypes
import mmap
import os
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join('/run/media/USERDATA-mmcblk0p2', 'py'),
           os.path.join(HERE, '..', '..', 'python'),
           os.path.join(HERE, '..', 'python'),
           os.path.join(HERE, '..', '..', 'artifacts', 'userdata', 'py')):
    if os.path.exists(os.path.join(_p, 'fogccc.py')):
        sys.path.insert(0, _p)
        break
import fogccc  # noqa: E402

REG_BASE = 0x43C00000
R_CTRL, R_DPUSH, R_DSTAT = 0x00, 0x440, 0x444
PUSH_WR_MARK = 0xA5400000   # command writes carry their destination in WDATA[31:20]
CTRL_DIRTY_FLUSH = 1 << 5
FIFO_DEPTH = 256

fails = []


def raw_push(oid, tag):
    """bypass the binding: write DIRTY_PUSH with a fixed tag (negative control)"""
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=REG_BASE)
    struct.pack_into('<I', regs, R_DPUSH, PUSH_WR_MARK | ((tag & 0xF) << 12) | (oid & 0xFFF))
    regs.close()
    os.close(fd)


def main():
    n = 512
    if '-n' in sys.argv:
        n = int(sys.argv[sys.argv.index('-n') + 1])
    neg = '--neg' in sys.argv

    with fogccc.FOGCCC() as fpga:
        fpga.build_graph(n, avg_refs=3)

        # ---- 1) full mark, and the live set from the bitmap -------------------
        fpga.set_roots([0])
        c0 = fpga.mark_sw([0])                     # oracle: the C BFS
        r0 = fpga.mark()                           # hardware full mark
        marks = fpga.dump_marks(n)
        live = set(i for i in range(n) if marks[i])
        print('full mark : marked=%d oracle=%d live=%d STATUS=0x%X'
              % (r0['marked'], c0, len(live), fpga.status()))
        if r0['marked'] != c0 or len(live) != c0:
            print('FAIL: full mark disagrees with the C BFS oracle')
            fails.append('full')

        # ---- 2) incremental epoch: push one marked container + one unmarked ---
        unmarked = [i for i in range(n) if i not in live and i != 0]
        pushed_ids = [sorted(live)[0], unmarked[0]]
        marks_before = fpga.dirty_counts()
        before = fpga.dirty_status()
        if before['occ'] or before['overflow']:
            print('FAIL: the FIFO is not clean after a full mark (occ=%d ovf=%d)'
                  % (before['occ'], before['overflow']))
            fails.append('clean')
        for oid in pushed_ids:
            if neg:
                raw_push(oid, 0x5)                 # constant tag: only the first lands
            else:
                fpga.dirty_push(oid)
        # ---- 2b) verified push: the same records, confirmed one by one ------
        if not neg:
            extra = unmarked[1:3]
            got = [fpga.dirty_push_verified(oid) for oid in extra]
            pushed_ids += extra
            print('verified push: %s (expect True/True)' % got)
            if not all(got):
                print('FAIL: dirty_push_verified() could not confirm a push')
                fails.append('verified')
            extra2 = unmarked[3:5]
            got2 = [fpga.dirty_push_acked(oid) for oid in extra2]
            pushed_ids += extra2
            print('acked push   : %s (expect True/True)' % got2)
            if not all(got2):
                print('FAIL: dirty_push_acked() could not confirm the id')
                fails.append('acked')
        time.sleep(0.002)
        r1 = fpga.mark_incremental()               # roots stay 0, no flush
        cnt = fpga.dirty_counts()
        marks = fpga.dump_marks(n)
        cum = set(i for i in range(n) if marks[i])
        oracle = fpga.mark_sw([0] + pushed_ids)    # clobbers the bitmap: do it last
        expect_new = oracle - c0
        print('incremental: epoch_marked=%d (expect %d) cumulative=%d oracle=%d | '
              'pushed=%d popped=%d drained=%d | occ=%d'
              % (r1['marked'], expect_new, len(cum), oracle,
                 cnt['pushed'] - marks_before['pushed'], cnt['popped'] - marks_before['popped'],
                 cnt['drained'], fpga.dirty_status()['occ']))
        if r1['marked'] != expect_new:
            print('FAIL: the epoch marked %d, the oracle expects %d (pushes lost?)'
                  % (r1['marked'], expect_new))
            fails.append('epoch')
        if len(cum) != oracle:
            print('FAIL: cumulative marked=%d != oracle=%d' % (len(cum), oracle))
            fails.append('cum')
        d_push = cnt['pushed'] - marks_before['pushed']
        d_pop = cnt['popped'] - marks_before['popped']
        if d_push != cnt['drained'] or d_pop != d_push:
            print('FAIL: counters disagree (pushed=%d popped=%d drained=%d)'
                  % (d_push, d_pop, cnt['drained']))
            fails.append('counts')
        if d_push < len(pushed_ids):
            print('FAIL: pushed=%d < %d (a barrier record was lost)'
                  % (d_push, len(pushed_ids)))
            fails.append('lost')

        # ---- 3) overflow: saturate while the engine is idle, then flush -------
        fpga.dirty_flush()                          # arm ...
        fpga.mark()                                 # ... a full-mark START consumes it
        time.sleep(0.002)
        for i in range(FIFO_DEPTH + 44):
            fpga.dirty_push(i % n)
        time.sleep(0.002)
        st = fpga.dirty_status()
        c = fpga.dirty_counts()
        print('overflow  : occ=%d overflow=%d pushed=%d (expect %d / 1 / %d)'
              % (st['occ'], st['overflow'], c['pushed'], FIFO_DEPTH, FIFO_DEPTH))
        if st['overflow'] != 1 or c['pushed'] != FIFO_DEPTH:
            print('FAIL: the saturated FIFO must latch overflow and stop counting')
            fails.append('ovf')
        fpga.dirty_flush()                          # arm ...
        fpga.mark()                                 # ... consumed at the full-mark start
        time.sleep(0.002)
        st = fpga.dirty_status()
        c = fpga.dirty_counts()
        if st['occ'] or st['overflow'] or c['pushed'] or c['popped']:
            print('FAIL: dirty_flush() did not clear (occ=%d ovf=%d pushed=%d)'
                  % (st['occ'], st['overflow'], c['pushed']))
            fails.append('flush')

    print('DIRTY_API_RESULT %s' % ('OK' if not fails else 'FAIL:' + ','.join(fails)))
    print('DIAG_DONE')
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.exit(main())