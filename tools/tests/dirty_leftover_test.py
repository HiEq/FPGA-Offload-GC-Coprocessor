#!/usr/bin/env python3
# ============================================================
# dirty_leftover_test.py - a leftover barrier record must not perturb the C API's
# full mark (Phase 3A; AGENTS.md #18)
#
# The dirty FIFO survives process restarts and the engine force-rescans a pushed
# id even in a bm_keep=0 (full mark) epoch.  A full mark therefore has to flush
# it: the C API writes CTRL = CLEAR_Q | DIRTY_FLUSH.
#
# Sequence: leave two ids in the FIFO, then run the C test_main binary and
# require its whole suite to pass.
#   Negative control (pre-fix binary, CLEAR_Q only): the engine rescans those two
#   ids right after the bitmap clear has unmarked them -> two extra marks
#   (Test 1 MISMATCH) and q_tail = marked + 2 -> test_main reports FAILED.
#
# usage: python3 dirty_leftover_test.py [path/to/test_main]
# exit 0 = test_main passed with the leftovers present
# ============================================================
import mmap
import os
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import side_table_test as C

R_CTRL, R_DSTAT, R_DPUSH, R_DPUSHED = 0x00, 0x444, 0x440, 0x44C
CTRL_DIRTY_FLUSH = 1 << 5
CTRL_WR_MARK = 0xA5000000   # command writes carry their destination in WDATA[31:20]
PUSH_WR_MARK = 0xA5400000
LEFTOVER = (1, 2)          # small ids: inside every row of the C sweep

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.REG_BASE)
rr = lambda o: struct.unpack_from('<I', regs, o)[0]
wr = lambda o, v: struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)

exe = sys.argv[1] if len(sys.argv) > 1 else './bin/test_main'


def push(oid):
    # command-with-tag: the tag must differ from the last accepted one
    tag = (((rr(R_DSTAT) >> 16) & 0xF) + 1) & 0xF
    wr(R_DPUSH, PUSH_WR_MARK | (tag << 12) | (oid & 0xFFF))


def main():
    if rr(0x30) != 0x47434343 or rr(0x34) != 0x00040301:
        print('FAIL magic/version 0x%08X/0x%08X (need v4.2)' % (rr(0x30), rr(0x34)))
        return 1

    wr(R_CTRL, CTRL_WR_MARK | CTRL_DIRTY_FLUSH)           # arm the flush ...
    wr(R_CTRL, CTRL_WR_MARK | 0x1)                        # ... a full-mark START consumes it (driver order)
    for _ in range(2000):
        if rr(R_CTRL) & (1 << 31):
            break
        time.sleep(0.0002)
    time.sleep(0.002)
    for oid in LEFTOVER:
        push(oid)
    time.sleep(0.005)
    st = rr(R_DSTAT)
    occ, pushed = st & 0x1FF, rr(R_DPUSHED) & 0xFFFF
    print('leftover barrier records: occ=%d pushed=%d ids=%s' % (occ, pushed, list(LEFTOVER)))
    # this board redelivers a store, so occ can exceed the logical count by one
    if not (len(LEFTOVER) <= occ <= len(LEFTOVER) + 2 and pushed >= len(LEFTOVER)):
        print('FAIL: could not leave %d records in the dirty FIFO' % len(LEFTOVER))
        return 1

    r = subprocess.run([exe], capture_output=True, text=True, cwd=os.getcwd())
    out = (r.stdout or '') + (r.stderr or '')
    ok = ('ALL PASS' in out) and r.returncode == 0
    bad = [l.strip() for l in out.splitlines()
           if ('MISMATCH' in l) or ('q_tail' in l) or ('FAILED' in l) or ('STATUS=' in l)]
    print('test_main: rc=%d verdict=%s' % (r.returncode, 'ALL PASS' if ok else 'FAILED'))
    for l in bad[:6]:
        print('  | ' + l)
    print('DIRTY_LEFTOVER_RESULT %s' % ('OK' if ok else 'FAIL'))
    regs.close()
    os.close(fd)
    print('DIAG_DONE')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())