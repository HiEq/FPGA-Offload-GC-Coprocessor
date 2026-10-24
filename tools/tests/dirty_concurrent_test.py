#!/usr/bin/env python3
# ============================================================
# dirty_concurrent_test.py - Phase 3B: concurrent mutator + remark epoch
#
# Protocol under test (no RTL/interface change from Phase 3A):
#   epoch 1  full mark    (bm_keep=0, roots, flush)
#   epoch 2  incremental  + a mutator thread that pushes WHILE the engine
#            drains.  Seeded with BATCH_H barrier writes to one hot container
#            (a long ref list, so each record costs a full forced rescan): the
#            epoch stays live for milliseconds and the mutator's first push
#            cannot land after it finished.
#   epoch 3  remark       (bm_keep=1, roots=0, NO flush) after the mutator
#            stopped: closes the window where a record lands in the cycle the
#            engine decides to finish.
#
# DIRTY_PUSH is a command-with-tag: this board's AXI-Lite write path delivers
# every store twice, so the tag must change per logical push.
#
# FIFO budget: BATCH_H + BUDGET = 250 <= 256, so a full dirty FIFO (and its
# sticky overflow flag) is impossible by construction, not by timing.
#
# Checks (CPU oracle over the FINAL graph):
#   marked == closure(final edges, live); free list == the never-marked set;
#   pushed == popped == drained(epoch2) + drained(epoch3); no overflow bit in
#   DIRTY_STAT; no error bit in STATUS; and at least one mutator push landed
#   while the incremental epoch was live -- the mutator counts that itself,
#   because a single sampled busy bit is a race, not evidence.
# Neg control: the mutator writes edges but never pushes (barrier missing) ->
#   the new targets must stay unmarked.
#
# usage: python3 dirty_concurrent_test.py   (root, /dev/mem, PL = v4.2, tag rule)
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

R_CTRL = 0x00
R_COUNT = 0x08
R_ROOTS = 0x0C
R_MARKED = 0x10
R_BASE = 0x04
R_STATUS = 0x20
R_BMADDR, R_BMDATA = 0x24, 0x28
R_FCOUNT, R_FDATA = 0x38, 0x3C
R_DPUSH, R_DSTAT, R_DDRAIN = 0x440, 0x444, 0x448
R_DPUSHED, R_DPOPPED = 0x44C, 0x450
R_RLIST = 0x40

CTRL_START, CTRL_CLEAR_Q, CTRL_DONE = 1, 4, (1 << 31)
CTRL_BM_KEEP, CTRL_DIRTY_FLUSH = (1 << 4), (1 << 5)
CTRL_WR_MARK = 0xA5000000   # command writes carry their destination in WDATA[31:20]
PUSH_WR_MARK = 0xA5400000
STATUS_FREEBUSY, STATUS_ERR = (1 << 5), 0x0F   # STATUS[4] = engine idle
DSTAT_OVF, DSTAT_COUNT = (1 << 9), 0x1FF
BASE = C.GRAPH_BASE
ROUNDS = 5           # 1 main round + 4 stress rounds
BATCH_H = 150        # epoch-2 seed: barrier writes to the hot container
BUDGET = 100         # concurrent mutator pushes (BATCH_H + BUDGET < 256)
HEAVY_REFS = 1024    # ref words of the hot container -> one slow forced rescan

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.REG_BASE)
gph = mmap.mmap(fd, C.GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.GRAPH_BASE)
rr = lambda o: struct.unpack_from('<I', regs, o)[0]
wr = lambda o, v: struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)

fails = []


class Pusher:
    """command-with-tag DIRTY_PUSH with the AGENTS #20 id-level ack.

    The tag must change per logical push (the platform redelivers stores).  After
    each write DIRTY_STAT[31:20]/[19:16] is read back: only when both the tag and
    the id match did this record land.  A mismatch retries with a fresh tag (a
    repeated id is only a forced re-scan); a sticky overflow or an exhausted retry
    budget counts as a giveup, which the verdict below treats as a failure.

    ``--plain-push`` restores the old fire-and-forget push: that is the negative
    control for this path (the cold-window loss then shows up as a short count or
    as `marked != oracle`).
    """

    def __init__(self, ack=True):
        self.lock = threading.Lock()
        self.tag = None
        self.ack = ack
        self.retries = 0
        self.giveups = 0

    def __call__(self, oid):
        with self.lock:
            for _ in range(5 if self.ack else 1):
                if self.tag is None:
                    self.tag = (rr(R_DSTAT) >> 16) & 0xF
                self.tag = (self.tag + 1) & 0xF
                wr(R_DPUSH, PUSH_WR_MARK | (self.tag << 12) | (oid & 0xFFF))
                if not self.ack:
                    return True
                for _ in range(8):
                    st = rr(R_DSTAT)
                    if (st >> 9) & 1:                     # spilled/dropped
                        self.giveups += 1
                        return False
                    if (((st >> 16) & 0xF) == self.tag and
                            ((st >> 20) & 0xFFF) == (oid & 0xFFF)):
                        return True
                self.retries += 1
            self.giveups += 1
            return False


PLAIN_PUSH = '--plain-push' in sys.argv
push = Pusher(ack=not PLAIN_PUSH)


def wait_done_and_idle(timeout=20.0, sample_busy=False):
    saw = False
    t0 = time.time()
    while time.time() < t0 + timeout:
        if sample_busy and ((rr(R_STATUS) >> 4) & 1) == 0:
            saw = True                       # engine left S_IDLE -> epoch live
        if rr(R_CTRL) & CTRL_DONE:
            break
        time.sleep(0.00002)
    t0 = time.time()
    while time.time() < t0 + timeout:
        if (rr(R_STATUS) & STATUS_FREEBUSY) == 0:
            break
        time.sleep(0.0001)
    return (rr(R_CTRL) & CTRL_DONE) != 0, saw


def start_epoch(keep):
    wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q)
    time.sleep(0.001)
    wr(R_CTRL, CTRL_WR_MARK | CTRL_START | (CTRL_BM_KEEP if keep else 0))
    _ = rr(R_CTRL)      # read-back: the posted START has been accepted


def read_marks(n):
    out = []
    for o in range(n):
        wr(R_BMADDR, o)
        _ = rr(R_BMADDR)
        out.append((rr(R_BMDATA) >> (o & 31)) & 1)
    return out


def main():
    if rr(0x30) != 0x47434343 or rr(0x34) != 0x00040300:
        print('FAIL magic/version 0x%08X/0x%08X (need v4.2)' % (rr(0x30), rr(0x34)))
        return 1
    print('magic/version OK: 0x%08X / 0x00040300' % rr(0x30))

    N, SEED = 1024, 12345
    g = C.build_container_graph(N, SEED)
    root = g['root']
    live = set(i for i in range(N) if C.bfs_marked(g['refs'], g['root'])[i])
    live_l = sorted(live)
    garbage = [i for i in range(N) if i not in live]
    ref_base = (N * 16 + 0xFFF) & ~0xFFF
    edges = [list(r) + [0xFFFFFFFF] for r in g['refs']]
    offs = [0] * N

    # Hot container: a live object whose ref list is extended with HEAVY_REFS
    # self references.  Marking it is free (it is already marked) but the
    # engine still reads every ref word, so one DIRTY_PUSH of it costs a full
    # ref-list rescan.  That is what keeps the incremental epoch alive long
    # enough for the mutator to overlap it.  Reachability is unchanged (all the
    # new refs point at an object that is already live).
    HEAVY = live_l[-1]
    pool_live = [i for i in live_l if i != HEAVY]
    hidx = edges[HEAVY].index(0xFFFFFFFF)
    edges[HEAVY] = edges[HEAVY][:hidx] + [HEAVY] * HEAVY_REFS + [0xFFFFFFFF]
    print('graph: n=%d live=%d garbage=%d heavy=%d heavy_refs=%d seed=%d'
          % (N, len(live), len(garbage), HEAVY, HEAVY_REFS, SEED))

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

    touched_lock = threading.Lock()
    touched = []
    live_push = [0]      # pushes the mutator made while the epoch was live
    tm = {}              # concurrency-window timestamps

    def mutator(go_evt, do_push):
        """append one edge to each of BUDGET distinct live containers"""
        rng = random.Random(SEED + 1)
        pool = list(pool_live)
        rng.shuffle(pool)                # setup before the wait: first push is quick
        go_evt.wait()
        tm['m0'] = time.time()
        cnt = 0
        while cnt < BUDGET and pool:
            c = pool.pop()
            t = rng.choice(garbage)
            struct.pack_into('<I', gph, offs[c] + (len(edges[c]) - 1) * 4, t)
            struct.pack_into('<I', gph, offs[c] + len(edges[c]) * 4, 0xFFFFFFFF)
            edges[c].insert(len(edges[c]) - 1, t)
            _ = struct.unpack_from('<I', gph, offs[c])[0]     # fence: visible first
            if do_push:
                v = rr(R_CTRL)                                # live == epoch not done
                if cnt == 0:
                    tm['m1'] = time.time()
                    tm['ctrl'] = v
                if not (v & CTRL_DONE):
                    live_push[0] += 1                         # counted, not sampled
                push(c)                                       # then the barrier record
            with touched_lock:
                touched.append(c)
            cnt += 1
        tm['m2'] = time.time()
        return cnt

    def closure(seeds):
        seen = set(seeds)
        stack = list(seeds)
        while stack:
            c = stack.pop()
            for x in edges[c]:
                if x != 0xFFFFFFFF and x not in seen and x < N:
                    seen.add(x)
                    stack.append(x)
        return seen

    def run_cycle(do_push):
        """epoch1 full; epoch2 incremental + concurrent mutator; epoch3 remark"""
        del touched[:]
        live_push[0] = 0
        tm.clear()
        edges[:] = [list(r) + [0xFFFFFFFF] for r in g['refs']]
        edges[HEAVY] = edges[HEAVY][:hidx] + [HEAVY] * HEAVY_REFS + [0xFFFFFFFF]
        write_image(edges)
        wr(R_COUNT, N)
        wr(R_ROOTS, 1)
        wr(R_BASE, BASE)                  # 0x04: reset value is 0, never inherit it
        wr(R_RLIST, root)
        wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q | CTRL_DIRTY_FLUSH)
        start_epoch(False)
        wait_done_and_idle()
        e1 = rr(R_MARKED)
        wr(R_ROOTS, 0)
        # epoch 2 seed: BATCH_H barrier writes to the hot container.  The FIFO
        # is loaded before START, so the engine is busy from the first cycle.
        go_evt = threading.Event()
        th = threading.Thread(target=mutator, args=(go_evt, do_push))
        th.start()                       # warmed up and parked before the seed
        if do_push:
            for _ in range(BATCH_H):
                push(HEAVY)
        start_epoch(True)
        go_evt.set()                     # release: pushes start inside the epoch
        tm['go'] = time.time()
        done, saw_busy = wait_done_and_idle(sample_busy=True)
        tm['done'] = time.time()
        th.join()                        # mutator finishes its whole budget
        res = {'e1': e1, 'd2': rr(R_DDRAIN), 'saw': saw_busy, 'live_push': live_push[0],
               'tm': dict(tm)}
        start_epoch(True)                # remark: bm_keep, roots=0, NO flush
        wait_done_and_idle()
        res['d3'] = rr(R_DDRAIN)
        res['pushed'] = rr(R_DPUSHED)
        res['popped'] = rr(R_DPOPPED)
        res['dstat'] = rr(R_DSTAT)
        res['status'] = rr(R_STATUS)
        marks = read_marks(N)
        res['marked'] = {i for i in range(N) if marks[i]}
        fc = rr(R_FCOUNT)
        res['fids'] = set(rr(R_FDATA) & 0xFFF for _ in range(fc))
        res['touched'] = list(touched)
        return res

    def evaluate(res, do_push):
        oracle = closure(live | set(res['touched']))
        why = []
        if res['e1'] != len(live):
            why.append('epoch1 marked %d != live %d' % (res['e1'], len(live)))
        if do_push and not res['saw']:
            why.append('no STATUS sample while the epoch was live')
        if do_push and res['live_push'] < 1:
            why.append('no mutator push landed while the epoch was live')
        if do_push and push.giveups:
            why.append('%d push(es) could not be confirmed by the id-level ack' % push.giveups)
        if do_push and not (BATCH_H + BUDGET <= res['pushed'] < 2 * (BATCH_H + BUDGET)):
            why.append('pushed %d outside [%d, %d) (lost, or the tag rule stopped'
                       ' collapsing redeliveries)'
                       % (res['pushed'], BATCH_H + BUDGET, 2 * (BATCH_H + BUDGET)))
        if res['d2'] + res['d3'] != res['pushed']:
            why.append('drained %d+%d != pushed %d' % (res['d2'], res['d3'], res['pushed']))
        if res['popped'] != res['pushed']:
            why.append('popped %d != pushed %d' % (res['popped'], res['pushed']))
        if res['dstat'] & DSTAT_OVF:
            why.append('dirty FIFO overflow latched')
        if res['dstat'] & DSTAT_COUNT:
            why.append('dirty FIFO not empty (%d left)' % (res['dstat'] & DSTAT_COUNT))
        if res['status'] & STATUS_ERR:
            why.append('STATUS error bits 0x%X' % res['status'])
        if res['marked'] != oracle:
            why.append('marked %d != oracle %d (missing %s extra %s)'
                       % (len(res['marked']), len(oracle),
                          sorted(oracle - res['marked'])[:6], sorted(res['marked'] - oracle)[:6]))
        if res['fids'] != set(range(N)) - oracle:
            why.append('free list != never-marked set (free=%d expect=%d)'
                       % (len(res['fids']), N - len(oracle)))
        return oracle, why

    # ---- main round ----
    res = run_cycle(True)
    oracle, why = evaluate(res, True)
    print('round: e1=%d pushed=%d drained=%d(conc)+%d(remark) popped=%d | marked=%d oracle=%d |'
          ' busy_seen=%s live_pushes=%d/%d'
          % (res['e1'], res['pushed'], res['d2'], res['d3'], res['popped'],
             len(res['marked']), len(oracle), res['saw'], res['live_push'], BUDGET))
    if why:
        print('FAIL round: %s' % '; '.join(why))
        fails.append('round')
    t = res['tm']
    if 'go' in t:
        print('timing: epoch2_window_us=%.0f mutator_wake_us=%.0f first_push_us=%.0f'
              ' mutator_total_us=%.0f ctrl_at_first_push=0x%08X'
              % ((t['done'] - t['go']) * 1e6, (t.get('m0', t['go']) - t['go']) * 1e6,
                 (t.get('m1', t['go']) - t['go']) * 1e6, (t.get('m2', t['go']) - t['go']) * 1e6,
                 t.get('ctrl', 0)))

    # ---- stress rounds ----
    for k in range(1, ROUNDS):
        res = run_cycle(True)
        oracle, why = evaluate(res, True)
        print('stress %d: pushed=%d drained=%d/%d popped=%d marked=%d oracle=%d busy=%s'
              ' live_pushes=%d -> %s'
              % (k, res['pushed'], res['d2'], res['d3'], res['popped'],
                 len(res['marked']), len(oracle), res['saw'], res['live_push'],
                 'OK' if not why else 'FAIL'))
        if why:
            print('  stress %d: %s' % (k, '; '.join(why)))
            fails.append('stress%d' % k)

    # ---- negative control: mutator writes edges but never pushes ----
    res = run_cycle(False)
    missed = sorted(t for t in closure(live | set(res['touched'])) if t not in res['marked'])
    print('neg no-barrier: e1=%d pushed=%d drained=%d/%d marked=%d missed=%d'
          ' (pushed must be 0, missed > 0)'
          % (res['e1'], res['pushed'], res['d2'], res['d3'], len(res['marked']), len(missed)))
    if res['e1'] != len(live):
        print('NEG FAIL: epoch1 marked %d != live %d' % (res['e1'], len(live)))
        fails.append('neg e1')
    if res['pushed'] != 0:
        print('NEG FAIL: %d records were pushed' % res['pushed'])
        fails.append('negpush')
    if not missed:
        print('NEG FAIL: without pushes the new targets were marked anyway')
        fails.append('neg')
    if res['dstat'] & DSTAT_OVF:
        print('NEG FAIL: dirty FIFO overflow latched')
        fails.append('negoverflow')
    if res['status'] & STATUS_ERR:
        print('NEG FAIL: STATUS error bits 0x%X' % res['status'])
        fails.append('negstatus')

    print('mode: %s | ack retries=%d giveups=%d'
          % ('plain push (negative control)' if PLAIN_PUSH else 'acked push', push.retries, push.giveups))
    print('DIRTY_CONCURRENT_RESULT %s' % ('OK' if not fails else 'FAIL:' + ','.join(fails)))
    wr(R_CTRL, CTRL_WR_MARK | CTRL_DIRTY_FLUSH)      # arm; the next process's full-mark start clears the FIFO
    regs.close()
    gph.close()
    os.close(fd)
    print('DIAG_DONE')
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.exit(main())