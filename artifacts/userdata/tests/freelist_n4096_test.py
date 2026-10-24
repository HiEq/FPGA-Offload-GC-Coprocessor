#!/usr/bin/env python3
# ============================================================
# freelist_n4096_test.py - all-free at the 4096 boundary
#
# The Phase-2 free-list scanner walks word-per-object with a 12-bit id.  A retired
# standalone simulation variant used to report this boundary as wrong:
# "n=4096 mode=1" failed from id 3936 on (got=0 exp=1, 273 errors).  Every board
# free-list check so far used n <= 1024, so this decides whether that was a stale
# testbench or a real RTL corner.
#
# Graph: 4096 objects, every ref_count 0, root_count 0 -> the engine marks
# nothing, so the scanner must report exactly 4096 free ids: no duplicates, none
# out of range, and the set must be 0..4095.
#
# usage: python3 freelist_n4096_test.py   (root, /dev/mem)
# ============================================================
import mmap
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import side_table_test as C

R_CTRL, R_BASE, R_COUNT, R_ROOTS, R_MARKED = 0x00, 0x04, 0x08, 0x0C, 0x10
R_STATUS, R_FCOUNT, R_FDATA = 0x20, 0x38, 0x3C
CTRL_START, CTRL_CLEAR_Q, CTRL_DIRTY_FLUSH, CTRL_DONE = 1, 4, (1 << 5), (1 << 31)
STATUS_FREEBUSY = 1 << 5
BASE = C.GRAPH_BASE
N = 4096

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.REG_BASE)
gph = mmap.mmap(fd, C.GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.GRAPH_BASE)
rr = lambda o: struct.unpack_from('<I', regs, o)[0]
wr = lambda o, v: struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)


def main():
    if rr(0x30) != 0x47434343 or rr(0x34) != 0x00040200:
        print('FAIL magic/version 0x%08X/0x%08X (need v4.2)' % (rr(0x30), rr(0x34)))
        return 1
    print('magic/version OK: 0x%08X / 0x00040200' % rr(0x30))

    # headers only: id, ref_count 0, ref_addr irrelevant
    hdr = bytearray(N * 16)
    for i in range(N):
        struct.pack_into('<IIII', hdr, i * 16, i, 0, BASE + 0x8000, 0)
    gph[0:len(hdr)] = bytes(hdr)

    wr(R_BASE, BASE)
    wr(R_COUNT, N)
    wr(R_ROOTS, 0)                      # nothing is reachable -> nothing is marked
    wr(R_CTRL, CTRL_CLEAR_Q | CTRL_DIRTY_FLUSH)
    time.sleep(0.002)
    wr(R_CTRL, CTRL_START)

    t0 = time.time()
    while time.time() < t0 + 20.0 and not (rr(R_CTRL) & CTRL_DONE):
        time.sleep(0.00005)
    if not (rr(R_CTRL) & CTRL_DONE):
        print('FAIL: DONE never asserted')
        return 1
    t0 = time.time()
    while time.time() < t0 + 20.0 and (rr(R_STATUS) & STATUS_FREEBUSY):
        time.sleep(0.0001)

    marked = rr(R_MARKED)
    fc = rr(R_FCOUNT)
    ids = [rr(R_FDATA) & 0xFFF for _ in range(fc)]
    uniq = set(ids)
    dups = len(ids) - len(uniq)
    exp = set(range(N))
    missing = sorted(exp - uniq)
    extra = sorted(uniq - exp)
    print('N=%d all-free: marked=%d free_count=%d popped=%d dup=%d out_of_range=%d missing=%d'
          % (N, marked, fc, len(ids), dups, len(extra), len(missing)))
    if marked != 0:
        print('FAIL: marked=%d (no roots, nothing may be marked)' % marked)
    if fc != N:
        print('FAIL: free_count=%d != %d' % (fc, N))
    if dups or extra:
        print('FAIL: duplicate/out-of-range free ids (dup=%d extra=%s)' % (dups, extra[:6]))
    # the diagnostic that matters: which ids are missed
    if len(missing) <= 12:
        print('missing ids: %s' % missing)
    else:
        print('missing ids: %s … (%d total)' % (missing[:12], len(missing)))

    ok = (marked == 0) and (fc == N) and not dups and not extra and not missing
    print('FREELIST4096_RESULT %s' % ('OK' if ok else 'FAIL'))
    regs.close()
    gph.close()
    os.close(fd)
    print('DIAG_DONE')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())