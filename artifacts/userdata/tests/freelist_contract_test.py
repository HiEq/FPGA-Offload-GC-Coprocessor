#!/usr/bin/env python3
# ============================================================
# freelist_contract_test.py - Phase 2 free-list software contract
#
# The scanner borrows the bitmap read port while STATUS[5]=1, and the pop
# port only returns a stable list after the scan ends.  Both rules are
# enforced by convention, not by hardware, so this test violates them on
# purpose and checks the documented consequences against the CPU oracle:
#
#   A  probe-during-scan : reading BM_DATA while STATUS[5]=1 returns the
#                          scanner's word (mismatch vs the oracle), while the
#                          scan result itself must stay exact (no corruption).
#   B  naive early read  : reading FREE_COUNT while the scan still runs and
#                          popping that many ids truncates the free list
#                          (missing ids vs the oracle).
#   C  documented flow   : DONE -> STATUS[5]=0 -> FREE_COUNT -> pop is exact.
#
# The assertions are on the documented consequences, so the test can fail:
# disable the borrow mux (A) or make the scan instant (B) and the check
# reports the hazard as absent.
#
# usage:  python3 freelist_contract_test.py
# exit 0 = every documented consequence observed
# ============================================================
import mmap
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import side_table_test as C

R_CTRL = 0x00
R_STATUS = 0x20
R_BMADDR = 0x24
R_BMDATA = 0x28
R_FCOUNT = 0x38
R_FDATA = 0x3C
CTRL_START, CTRL_CLEAR_Q, CTRL_DONE = 1, 4, (1 << 31)
STATUS_FREEBUSY = 1 << 5

N = 4096
SEED = 12345

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.REG_BASE)
gph = mmap.mmap(fd, C.GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.GRAPH_BASE)


def rr(o):
    return struct.unpack_from('<I', regs, o)[0]


def wr(o, v):
    struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)


g = C.build_container_graph(N, SEED)
full = C.bfs_marked(g['refs'], g['root'])
exp_free = [i for i in range(N) if not full[i]]
img, _ = C.graph_buffer(g, False)
print('contract graph n=%d live=%d garbage=%d seed=%d' % (N, sum(full), N - sum(full), SEED))


def start_run():
    gph[0:len(img)] = img
    time.sleep(0.02)
    wr(0x40, g['root'])
    wr(0x0C, 1)
    wr(0x04, C.GRAPH_BASE)
    wr(0x08, N)
    wr(R_CTRL, CTRL_CLEAR_Q)
    time.sleep(0.002)
    wr(R_CTRL, CTRL_START)
    _ = rr(R_CTRL)
    time.sleep(0.0002)


def wait_done_tight(limit=2.0):
    t0 = time.time()
    while time.time() - t0 < limit:
        if rr(R_CTRL) & CTRL_DONE:
            return True
    return False


def wait_busy_clear(limit=2.0):
    t0 = time.time()
    while time.time() - t0 < limit:
        if (rr(R_STATUS) & STATUS_FREEBUSY) == 0:
            return True
        time.sleep(0.00002)
    return False


fails = []

# ---------------- A: probe during the scan ----------------
print('--- A probe-during-scan ---')
start_run()
probe_reads = 0
probe_bad = 0
caught = False
o = 0
t0 = time.time()
idle_t = None
while time.time() - t0 < 3.0:
    st = rr(R_STATUS)
    if st & STATUS_FREEBUSY:
        caught = True
        wr(R_BMADDR, o)
        hb = (rr(R_BMDATA) >> (o & 31)) & 1
        if hb != full[o]:
            probe_bad += 1
        probe_reads += 1
        o = (o + 1) % 64
    if (st >> 4) & 1:
        if idle_t is None:
            idle_t = time.time()
        if not (st & STATUS_FREEBUSY) and (time.time() - idle_t) > 0.001:
            break
    else:
        idle_t = None
wait_busy_clear()
fc = rr(R_FCOUNT)
ids = [rr(R_FDATA) & 0xFFF for _ in range(fc)]
A_free_ok = (sorted(ids) == exp_free)
print('A: busy_caught=%s probe_reads=%d mismatches=%d | free_count=%d expect=%d exact=%s'
      % (caught, probe_reads, probe_bad, fc, len(exp_free), A_free_ok))
if not caught:
    print('A: INCONCLUSIVE (scan window not captured)')
    fails.append('A-window')
elif probe_bad == 0:
    print('A: FAIL hazard NOT observed (probe must read the scanner word while busy)')
    fails.append('A-hazard')
if not A_free_ok:
    print('A: FAIL probing during the scan changed the free list')
    fails.append('A-corrupt')

# ---------------- B: naive early read ----------------
print('--- B naive-early-read ---')
start_run()
ran = wait_done_tight()
busy_caught = False
t0 = time.time()
while time.time() - t0 < 0.002:
    if rr(R_STATUS) & STATUS_FREEBUSY:
        busy_caught = True
        break
fce = rr(R_FCOUNT)                      # naive read while the scan still runs
ids_e = [rr(R_FDATA) & 0xFFF for _ in range(fce)]
sset = set(ids_e)
missing = [i for i in exp_free if i not in sset]
extra = [i for i in sorted(sset) if i not in exp_free]
# evidence: the count keeps growing while the scan owns the bitmap
traj = [fce]
t1 = time.time()
while time.time() - t1 < 0.002:
    st = rr(R_STATUS)
    c = rr(R_FCOUNT)
    if c != traj[-1]:
        traj.append(c)
    if (st & STATUS_FREEBUSY) == 0 and len(traj) > 1:
        break
wait_busy_clear()
bfc = rr(R_FCOUNT)
print('B: done=%s busy_caught=%s early_count=%d final_count=%d naive_missing=%d extra=%d traj=%s'
      % (ran, busy_caught, fce, bfc, len(missing), len(extra), traj))
if not busy_caught:
    print('B: INCONCLUSIVE (scan window not captured)')
    fails.append('B-window')
elif len(missing) == 0 or len(traj) < 2:
    print('B: FAIL early read was already the final list (no partial state observed)')
    fails.append('B-hazard')
else:
    print('B: partial state observed, missing_first=%s' % missing[:8])
while rr(R_STATUS) & STATUS_FREEBUSY:
    time.sleep(0.00002)

# ---------------- C: documented flow ----------------
print('--- C documented-flow ---')
start_run()
wait_done_tight()
wait_busy_clear()
fc2 = rr(R_FCOUNT)
ids2 = [rr(R_FDATA) & 0xFFF for _ in range(fc2)]
C_ok = (sorted(ids2) == exp_free)
print('C: free_count=%d expect=%d exact=%s' % (fc2, len(exp_free), C_ok))
if not C_ok:
    fails.append('C')

# ---------------- D: START while the scan owns the bitmap ----------------
print('--- D start-during-scan ---')
start_run()
into_scan = False
t0 = time.time()
while time.time() - t0 < 0.002:
    if rr(R_STATUS) & STATUS_FREEBUSY:
        into_scan = True
        break
st_mid = rr(R_STATUS)
wr(R_CTRL, CTRL_START)                  # re-arm a new run mid-scan (no CLEAR_Q)
_ = rr(R_CTRL)
wait_done_tight()
wait_busy_clear()
fc3 = rr(R_FCOUNT)
ids3 = [rr(R_FDATA) & 0xFFF for _ in range(fc3)]
st_end = rr(R_STATUS)
D_exact = (sorted(ids3) == exp_free)
print('D: scan_seen=%s status_mid=0x%X | free_count=%d expect=%d exact=%s | status_end=0x%X'
      % (into_scan, st_mid, fc3, len(exp_free), D_exact, st_end))
if not into_scan:
    print('D: INCONCLUSIVE (scan window not captured)')
    fails.append('D-window')
elif not (D_exact and (st_end & 0x1F) == 0x10):
    print('D: FAIL re-arm during the scan did not end in a clean exact run')
    fails.append('D')

print('CONTRACT_RESULT %s' % ('OK' if not fails else ('FAIL:' + ','.join(fails))))
regs.close()
gph.close()
os.close(fd)
print('DIAG_DONE')