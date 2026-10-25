#!/usr/bin/env python3
# ============================================================
# dirty_probe.py - characterise the 2x push count seen on the board
#
# One CPU store to 0x440 seems to enqueue TWO records.  This probe measures
# how the multiplier depends on the access width and on back-to-back stores.
# ============================================================
import mmap
import os
import struct
import time

REG_BASE = 0x43C00000
R_CTRL = 0x00
R_DPUSH = 0x440
R_DSTAT = 0x444
R_DPUSHED = 0x44C
R_DPOPPED = 0x450

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=REG_BASE)
rr = lambda o: struct.unpack_from('<I', regs, o)[0]
wr = lambda o, v: struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)
stat = lambda: (rr(R_DPUSHED), rr(R_DPOPPED), rr(R_DSTAT) & 0x1FF)


def flush():
    wr(R_CTRL, 1 << 5)          # DIRTY_FLUSH
    time.sleep(0.002)


print('--- one 32-bit store per push ---')
flush()
print('after flush: pushed=%d popped=%d occ=%d' % stat())
for v in (5, 6, 7):
    wr(R_DPUSH, v)
    print('  push %2d -> pushed=%d popped=%d occ=%d' % (v, *stat()))

print('--- 8-bit store to 0x440 ---')
flush()
struct.pack_into('<B', regs, R_DPUSH, 9)
print('  -> pushed=%d popped=%d occ=%d' % stat())

print('--- 16-bit store to 0x440 ---')
flush()
struct.pack_into('<H', regs, R_DPUSH, 11)
print('  -> pushed=%d popped=%d occ=%d' % stat())

print('--- 32-bit store at 0x442 (unaligned-ish) ---')
flush()
struct.pack_into('<I', regs, 0x442, 0x1112)
print('  -> pushed=%d popped=%d occ=%d' % stat())

print('--- two back-to-back 32-bit stores, no read in between ---')
flush()
wr(R_DPUSH, 21)
wr(R_DPUSH, 22)
time.sleep(0.002)
print('  -> pushed=%d popped=%d occ=%d' % stat())

print('--- read 0x444 twenty times, then check pushed ---')
flush()
n0 = rr(R_DPUSHED)
for _ in range(20):
    _ = rr(R_DSTAT)
print('  reads of 0x444 added %d pushes' % (rr(R_DPUSHED) - n0))

print('--- read 0x440 twenty times (DIRTY_PUSH read = occupancy), then check ---')
flush()
n0 = rr(R_DPUSHED)
for _ in range(20):
    _ = rr(R_DPUSH)
print('  reads of 0x440 added %d pushes, occ=%d' % (rr(R_DPUSHED) - n0, rr(R_DSTAT) & 0x1FF))

print('--- read 0x44C twenty times ---')
flush()
n0 = rr(R_DPUSHED)
for _ in range(20):
    _ = rr(R_DPUSHED)
print('  reads of 0x44C added %d pushes' % (rr(R_DPUSHED) - n0))

flush()
regs.close()
os.close(fd)
print('PROBE_DONE')