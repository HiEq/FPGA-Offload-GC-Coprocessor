#!/usr/bin/env python3
# ============================================================
# diag_freelist.py - board diagnosis for the Phase 2 free-list anomaly
#
# Side-table n=512/seed=12345 reports FREE_COUNT=496 (expected 128).
# This script runs the same graph twice and records:
#   - the busy/idle/free_count trajectory around each run (tight poll)
#   - the exact popped id set vs the BFS oracle
#   - a few bitmap words through the probe port afterwards
# ============================================================
import mmap
import os
import struct
import sys
import time

sys.path.insert(0, '/run/media/USERDATA-mmcblk0p2/tests')
import side_table_test as C

R_CTRL = 0x00
R_MARKED = 0x10
R_CYCLES = 0x14
R_QTAIL = 0x1C
R_STATUS = 0x20
R_BMADDR = 0x24
R_BMDATA = 0x28
R_FREE_COUNT = 0x38
R_FREE_DATA = 0x3C

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.REG_BASE)
gph = mmap.mmap(fd, C.GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.GRAPH_BASE)


def rr(o):
    return struct.unpack_from('<I', regs, o)[0]


def wr(o, v):
    struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)


def dump_state(tag):
    st = rr(R_STATUS)
    print('%s CTRL=0x%08X STATUS=0x%08X(FREE_BUSY=%d IDLE=%d) FREE_COUNT=%d MARKED=%d CYCLES=%d'
          % (tag, rr(R_CTRL), st, (st >> 5) & 1, (st >> 4) & 1,
             rr(R_FREE_COUNT), rr(R_MARKED), rr(R_CYCLES)))


n = 512
seed = 12345
g = C.build_container_graph(n, seed)
full = C.bfs_marked(g['refs'], g['root'])
exp_free = [i for i in range(n) if not full[i]]
buf, _ = C.graph_buffer(g, False)

print('MAGIC=0x%08X VERSION=0x%08X' % (rr(0x30), rr(0x34)))
dump_state('before')


def run_once(run_tag):
    gph[0:len(buf)] = buf
    time.sleep(0.02)
    wr(0x40, g['root'])
    wr(0x0C, 1)
    wr(0x04, C.GRAPH_BASE)
    wr(0x08, n)
    wr(R_CTRL, 4)
    time.sleep(0.002)
    wr(R_CTRL, 1)
    _ = rr(R_CTRL)
    t0 = time.time()
    traj = []
    prev = None
    while time.time() < t0 + 2.0:
        st = rr(R_STATUS)
        fc = rr(R_FREE_COUNT)
        key = ((st >> 5) & 1, (st >> 4) & 1, fc)
        if key != prev:
            traj.append((time.time() - t0, key))
            prev = key
        if rr(R_CTRL) & 0x80000000:
            break
    print('%s done t=%.3fms ctrl=0x%08X traj=%d' %
          (run_tag, 1000 * (time.time() - t0), rr(R_CTRL), len(traj)))
    for t, k in traj[:48]:
        print('   %.3fms busy=%d idle=%d free=%d' % (1000 * t, k[0], k[1], k[2]))
    # wait for the scan to finish
    t1 = time.time()
    while time.time() < t1 + 2.0:
        st = rr(R_STATUS)
        if not (st >> 5) & 1:
            break
        time.sleep(0.00005)
    fc = rr(R_FREE_COUNT)
    ids = [rr(R_FREE_DATA) & 0xFFF for _ in range(fc)]
    sset = set(ids)
    missing = [i for i in exp_free if i not in sset]
    extra = [i for i in sorted(sset) if i not in exp_free]
    print('%s free_count=%d unique=%d expected=%d missing=%d extra=%d'
          % (run_tag, fc, len(sset), len(exp_free), len(missing), len(extra)))
    print('%s first_popped=%s' % (run_tag, ids[:12]))
    print('%s missing_first=%s' % (run_tag, missing[:12]))
    print('%s extra_first=%s' % (run_tag, extra[:12]))
    print('%s extra_mod32=%s' % (run_tag, sorted(set(i % 32 for i in extra))[:12]))
    dump_state(run_tag + ' post')


run_once('RUN1')
run_once('RUN2')

for w in (0, 11, 12, 15):
    wr(R_BMADDR, w)
    _ = rr(R_BMADDR)
    print('probe word %d = 0x%08X' % (w, rr(R_BMDATA)))

regs.close()
gph.close()
os.close(fd)
print('DIAG_DONE')