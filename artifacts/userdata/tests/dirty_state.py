#!/usr/bin/env python3
# ============================================================
# dirty_state.py - print the Phase-3 dirty FIFO state; --flush arms a flush.
#
# The board chain runs this between steps: a leftover barrier record is not
# harmful by itself (the engine only re-scans ids that are already in the set),
# but it perturbs the NEXT full mark -- the engine force-rescans ids the bitmap
# clear has just unmarked, so extra marks appear and the C API's
# `q_tail == marked` invariant fails.  That is the signature of the flake
# recorded in tools/logs/board_test_main_qtail_flake_20261022.log, reproduced
# on purpose by tools/tests/dirty_leftover_test.py.
#
# `--flush` writes CTRL[5], which only ARMS the flush: the engine applies it at
# the next accepted full-mark START (BM_KEEP=0, while idle).  The probe cannot
# clear the FIFO by itself, so a leftover record is still reported until a mark
# runs -- which is what the C API does (flush write, then START).
#
# usage: python3 dirty_state.py [--flush]
# exit 0 always; the caller decides what occ != 0 means
# ============================================================
import mmap
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import side_table_test as C

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.REG_BASE)
rr = lambda o: struct.unpack_from('<I', regs, o)[0]
wr = lambda o, v: struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)

if '--flush' in sys.argv:
    wr(0x00, 1 << 5)                     # CTRL[5] = DIRTY_FLUSH: arms; a full-mark START applies it
    time.sleep(0.005)

occ = rr(0x440) & 0x1FF
dstat = rr(0x444)
print('DIRTY_STATE occ=%d ovf=%d pending=%d tag=%X drained=%d pushed=%d popped=%d version=0x%08X'
      % (occ, (dstat >> 9) & 1, (dstat >> 10) & 1, (dstat >> 16) & 0xF,
         rr(0x448), rr(0x44C) & 0xFFFF, rr(0x450) & 0xFFFF, rr(0x34)))
print('DIAG_DONE')
regs.close()
os.close(fd)