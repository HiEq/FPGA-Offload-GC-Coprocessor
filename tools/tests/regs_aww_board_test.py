#!/usr/bin/env python3
# ============================================================
# regs_aww_board_test.py - board-side measurement for AGENTS #20.
#
# Question B2 answers: does a DIRTY_PUSH burst lose or forge a record only in
# the first window after a PL configuration, or also on a warm PL?
#
# Every round: clean the FIFO (arm + full-mark START + wait), push K ids that
# all have ref_count = 0 (so the expected mark set is exactly the pushed ids),
# run a full-mark epoch with roots = 0, then compare:
#   loss  = pushed ids that did not end up in the bitmap  (the dangerous case)
#   forged = marked ids that were never pushed            (ids < obj_count only;
#            a forged id >= obj_count is popped without marking -- invisible
#            in the bitmap, only its count differs, which duplicates mask)
#
# The verdict only asserts the warm rounds (round >= 1).  Round 0 runs as the
# first push sequence after a reboot and is reported, not asserted: it is the
# window AGENTS #20 records.
#
# --verified adds the read-back + retry mitigation.  MEASURED LIMIT (3 boots):
# retries=0 while round 0 still loses a record -- a foreign record can reuse the
# same 4-bit tag, so the read-back confirms the command reached the FIFO but not
# that the id did.  Kept as the A-side evidence for AGENTS #20.
#
# usage: python3 regs_aww_board_test.py     (root, /dev/mem, v4.2 bitstream)
# ============================================================
import mmap
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import side_table_test as C

R_CTRL, R_BASE, R_COUNT, R_ROOTS, R_MARKED = 0x00, 0x04, 0x08, 0x0C, 0x10
R_STATUS, R_BMADDR, R_BMDATA = 0x20, 0x24, 0x28
R_DPUSH, R_DSTAT, R_DDRAIN, R_DPUSHED, R_DPOPPED = 0x440, 0x444, 0x448, 0x44C, 0x450
CTRL_START, CTRL_CLEAR_Q, CTRL_DONE = 1, 4, (1 << 31)
CTRL_BM_KEEP, CTRL_DIRTY_FLUSH = (1 << 4), (1 << 5)
CTRL_WR_MARK = 0xA5000000   # command writes carry their destination in WDATA[31:20]
PUSH_WR_MARK = 0xA5400000
STATUS_FREEBUSY = 1 << 5
BASE, N = C.GRAPH_BASE, 64

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.REG_BASE)
gph = mmap.mmap(fd, C.GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=C.GRAPH_BASE)
rr = lambda o: struct.unpack_from('<I', regs, o)[0]
wr = lambda o, v: struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)
gw = lambda o, v: struct.pack_into('<I', gph, o, v & 0xFFFFFFFF)

_tag = None
VERIFIED = '--verified' in sys.argv
VERIFY_EFFECT = '--verify-effect' in sys.argv
ACKED = '--acked' in sys.argv
COST_MODE = '--cost' in sys.argv
MAX_RETRY = 4
_retries = 0
_giveups = 0


def push(oid):
    """DIRTY_PUSH with a fresh tag (the tag must change for every logical push).

    --verified adds the AGENTS #20 mitigation: read DIRTY_STAT[19:16] back and
    retry with a fresh tag when the record did not land (a repeated id is only a
    forced re-scan; a lost barrier record is the unsafe direction)."""
    global _tag, _retries, _giveups
    for _ in range(MAX_RETRY + 1):
        if _tag is None:
            _tag = (rr(R_DSTAT) >> 16) & 0xF
        _tag = (_tag + 1) & 0xF
        wr(R_DPUSH, PUSH_WR_MARK | (_tag << 12) | (oid & 0xFFF))
        if not (VERIFIED or ACKED):
            return True
        for _ in range(8):
            st = rr(R_DSTAT)
            if (st >> 9) & 1:              # sticky overflow: the record was dropped
                _giveups += 1
                return False
            if ((st >> 16) & 0xF) != _tag:
                continue
            if ACKED and ((st >> 20) & 0xFFF) != (oid & 0xFFF):
                continue                   # a forged record: keep retrying
            return True
        _retries += 1
    _giveups += 1
    return False


def wait_done(timeout=5.0):
    t0 = time.time()
    while time.time() < t0 + timeout:
        if rr(R_CTRL) & CTRL_DONE:
            break
        time.sleep(0.0002)
    t0 = time.time()
    while time.time() < t0 + timeout:
        if (rr(R_STATUS) & STATUS_FREEBUSY) == 0:
            break
        time.sleep(0.0002)
    return (rr(R_CTRL) & CTRL_DONE) != 0


def flush_now():
    """arm the flush, then apply it with a full-mark START (arm-and-consume)."""
    wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q | CTRL_DIRTY_FLUSH)
    wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q)
    time.sleep(0.002)
    wr(R_CTRL, CTRL_WR_MARK | CTRL_START)
    return wait_done()


def marks():
    out = []
    for o in range(N):
        wr(R_BMADDR, o)
        _ = rr(R_BMADDR)
        out.append((rr(R_BMDATA) >> (o & 31)) & 1)
    return out


def round_(ids, gap_writes):
    """one clean + push + epoch cycle; gap_writes = register writes between pushes"""
    # Quiesce the previous round's probe writes.  This does not stop a probe
    # write from being mis-paired into this epoch (see
    # board_regs_aww_probe_forge_20261023.log: an id-0 "forged" record appears
    # in every round, whose WDATA came from the bitmap probe).  An extra mark is
    # the SAFE direction, so only loss is asserted below.
    time.sleep(0.02)
    if not flush_now():
        return None
    for i, oid in enumerate(ids):
        push(oid)
        if gap_writes and i == 0:
            wr(R_COUNT, N)          # a different address, same-address-space traffic
            wr(R_ROOTS, 0)
    occ, pushed, tag = rr(R_DSTAT) & 0x1FF, rr(R_DPUSHED) & 0xFFFF, (rr(R_DSTAT) >> 16) & 0xF
    wr(R_CTRL, CTRL_WR_MARK | CTRL_START)          # roots are 0: only the dirty set does work
    ok = wait_done()
    marked = rr(R_MARKED)
    drain, popped = rr(R_DDRAIN), rr(R_DPOPPED) & 0xFFFF
    bits = marks()
    got = {i for i in range(N) if bits[i]}
    loss = sorted(set(ids) - got)
    forged = sorted(got - set(ids))
    return dict(ok=ok, occ=occ, pushed=pushed, tag=tag, marked=marked, drain=drain,
                popped=popped, loss=loss, forged=forged)


def probe(oid):
    wr(R_BMADDR, oid)
    _ = rr(R_BMADDR)
    return (rr(R_BMDATA) >> (oid & 31)) & 1


REF_OFF = 0x1000
CONTAINERS = list(range(8, 24))


def write_edges():
    """container c (8..23) -> target (32..47), one out-edge each, targets leaf."""
    for i, c in enumerate(CONTAINERS):
        t = 32 + i
        gw(c * 16 + 0, c); gw(c * 16 + 4, 1); gw(c * 16 + 8, BASE + REF_OFF + 8 * i)
        gw(REF_OFF + 8 * i + 0, t); gw(REF_OFF + 8 * i + 4, 0xFFFFFFFF)
        gw(t * 16 + 0, t); gw(t * 16 + 4, 0); gw(t * 16 + 8, BASE + REF_OFF + 0x800)


def full_mark_from(roots):
    for i, r in enumerate(roots):
        wr(0x40 + 4 * i, r)
    wr(R_ROOTS, len(roots))
    flush_now()                         # clean + BM_KEEP=0 START from those roots
    return wait_done()


def round_verify(ids):
    """push the containers, run the incremental-style epoch, verify the effect."""
    time.sleep(0.02)
    wr(R_ROOTS, 0)
    if not flush_now():
        return None
    for c in ids:
        push(c)
    wr(R_CTRL, CTRL_WR_MARK | CTRL_START)              # roots 0: only the dirty set does work
    if not wait_done():
        return None
    tgt = [32 + CONTAINERS.index(c) for c in ids]
    ok = all(probe(c) for c in ids) and all(probe(t) for t in tgt)
    fb = False
    if not ok:                          # the barrier record did not take effect
        fb = True
        if not full_mark_from(ids):     # fallback: full mark from the true roots
            return None
        ok = all(probe(t) for t in tgt) and all(probe(c) for c in ids)
    return dict(ok=ok, fallback=fb)


def main():
    if rr(0x30) != 0x47434343 or rr(0x34) != 0x00040301:
        print('FAIL magic/version 0x%08X/0x%08X (need the v4.2 bitstream)'
              % (rr(0x30), rr(0x34)))
        return 1
    wr(R_BASE, BASE)
    print('mode: %s' % ('acked push (tag+id read-back + retry, AGENTS #20)' if ACKED else 'verified push (tag read-back + retry, AGENTS #20)' if VERIFIED else 'plain push'))
    for i in range(N):                  # every object: ref_count 0 -> no traversal
        gw(i * 16 + 0, i)
        gw(i * 16 + 4, 0)
        gw(i * 16 + 8, BASE + 0x1000)
    wr(R_COUNT, N)
    wr(R_ROOTS, 0)

    plan = [(3, True)] + [(3, False)] * 9 + [(16, False)] * 5
    if COST_MODE:
        # cost of the id-level ack: 200 pushes, plain vs acked, same image
        def burst():
            for i in range(200):
                push(i % N)
        flush_now(); t0 = time.time(); burst(); t1 = time.time()
        wr(R_CTRL, CTRL_WR_MARK | CTRL_START); wait_done()
        globals()['ACKED'] = True
        flush_now(); t2 = time.time(); burst(); t3 = time.time()
        wr(R_CTRL, CTRL_WR_MARK | CTRL_START); wait_done()
        globals()['ACKED'] = False
        plain = (t1 - t0) / 200 * 1e6
        acked = (t3 - t2) / 200 * 1e6
        print('COST plain=%.1f us/push  acked=%.1f us/push  ratio=%.2fx  (retries=%d giveups=%d)'
              % (plain, acked, acked / plain if plain else 0.0, _retries, _giveups))
        print('COST_RESULT OK')
        print('DIAG_DONE')
        return 0
    if VERIFY_EFFECT:
        write_edges()
        warm_fail = warm_fb = 0
        for r, (k, _) in enumerate(plan):
            ids = CONTAINERS[:k]
            res = round_verify(ids)
            if res is None:
                print('round %-2d FAIL: the epoch or the fallback never reached DONE' % r)
                return 1
            print('round %-2d k=%-2d verify=%s%s'
                  % (r, k, 'OK' if res['ok'] else 'FAIL',
                     ' (fallback to a full mark, recovered)' if res['fallback'] else ''))
            if r > 0:
                if not res['ok']:
                    warm_fail += 1
                if res['fallback']:
                    warm_fb += 1
        print('VERIFY_EFFECT_RESULT %s (warm: %d/%d failed, %d/%d needed the fallback)'
              % ('OK' if warm_fail == 0 else 'FAIL:warm', warm_fail, len(plan) - 1,
                 warm_fb, len(plan) - 1))
        print('DIAG_DONE')
        return 0 if warm_fail == 0 else 1
    warm_loss = warm_forged = 0
    cold = None
    for r, (k, gap) in enumerate(plan):
        ids = list(range(8, 8 + k))
        res = round_(ids, gap)
        if res is None:
            print('round %-2d FAIL: the sanitising epoch never reached DONE' % r)
            return 1
        print('round %-2d k=%-2d gap=%-5s occ=%d pushed=%d tag=%X | marked=%d drained=%d '
              'popped=%d | loss=%s forged=%s%s'
              % (r, k, gap, res['occ'], res['pushed'], res['tag'], res['marked'],
                 res['drain'], res['popped'], res['loss'], res['forged'],
                 (' | retries=%d giveups=%d' % (_retries, _giveups)) if (VERIFIED or ACKED) else ''))
        if r == 0:
            cold = res
        else:
            if res['loss']:
                warm_loss += 1
            if res['forged']:
                warm_forged += 1

    print('cold round (first push sequence after the boot): loss=%s forged=%s'
          % (cold['loss'], cold['forged']))
    print('warm rounds: loss in %d/%d, extra marks in %d/%d (the safe direction)'
          % (warm_loss, len(plan) - 1, warm_forged, len(plan) - 1))
    # Only loss is asserted: an extra mark keeps an object alive too long (safe
    # for a collector), a lost barrier record misses a re-scan (unsafe).
    ok = (warm_loss == 0)
    print('REGS_AWW_RESULT %s' % ('OK' if ok else 'FAIL:warm'))
    print('DIAG_DONE')
    regs.close()
    gph.close()
    os.close(fd)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())