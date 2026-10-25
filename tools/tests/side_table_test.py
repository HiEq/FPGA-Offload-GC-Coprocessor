#!/usr/bin/env python3
# ============================================================
# side_table_test.py - Phase 1 side-table builder
#
# Build a real interpreter container graph with gc.get_referents()
# (which uses tp_traverse), map it into the existing FOGCCC
# object-header + reference-array format, and (in --hw mode)
# run the FPGA mark engine and compare against a CPU BFS oracle.
#
# usage:
#   python3 side_table_test.py --host [--n 512] [--seed 12345]
#   python3 side_table_test.py --host --neg          # logic negative control
#   python3 side_table_test.py --hw   [--n 512] [--seed 12345]
#   python3 side_table_test.py --hw --neg            # board negative control
#
# A test is only valid if the negative control can fail:
#   --neg corrupts one live object's ref_count in the hardware graph
#   (or in the host simulation), the comparison must detect it.
# ============================================================
import gc
import mmap
import os
import random
import struct
import sys
import time

REG_BASE   = 0x43C00000
GRAPH_BASE = 0x1E000000
GRAPH_SIZE = 0x100000          # 1 MiB
HDR_BASE   = 0x0000

R_CTRL, R_OBJ_BASE, R_OBJ_COUNT, R_ROOT_COUNT = 0x00, 0x04, 0x08, 0x0C
R_MARKED, R_CYCLES, R_Q_HEAD, R_Q_TAIL, R_ROOT_LIST, R_STATUS = 0x10, 0x14, 0x18, 0x1C, 0x40, 0x20
R_BM_ADDR, R_BM_DATA = 0x24, 0x28
R_MAGIC, R_VERSION = 0x30, 0x34
R_FREE_COUNT, R_FREE_DATA = 0x38, 0x3C
MAGIC_VALUE, VERSION_VALUE = 0x47434343, 0x00040301

CTRL_START, CTRL_CLEAR_Q, CTRL_DONE = 1, 4, (1 << 31)
CTRL_WR_MARK = 0xA5000000   # command writes carry their destination in WDATA[31:20]
MIN_CYCLES = 4096
N_MAX_HW = 4096


def parse_args(argv):
    opts = {'mode': 'host', 'n': 512, 'seed': 20261022, 'neg': False, 'selftest': False}
    if '--hw' in argv:
        opts['mode'] = 'hw'
    if '--host' in argv:
        opts['mode'] = 'host'
    if '--neg' in argv:
        opts['neg'] = True
    if '--selftest' in argv:
        opts['selftest'] = True
    if '--n' in argv:
        i = argv.index('--n')
        opts['n'] = int(argv[i + 1])
    if '--seed' in argv:
        i = argv.index('--seed')
        opts['seed'] = int(argv[i + 1])
    if opts['n'] < 1 or opts['n'] > N_MAX_HW:
        raise SystemExit('--n must be in [1, %d]' % N_MAX_HW)
    return opts


def build_container_graph(n, seed, live_frac=0.75):
    """Create a controlled tracked-container graph and extract tp_traverse edges."""
    rng = random.Random(seed)
    live = max(1, int(n * live_frac))
    if live > n:
        live = n
    objs = []
    for i in range(n):
        kind = rng.randrange(4)
        if kind < 3:
            objs.append([])          # 3/4 lists
        else:
            objs.append({})          # 1/4 dicts

    root = objs[0]

    # live: spanning tree from root, so every live object is reachable
    for i in range(1, live):
        p = rng.randrange(0, i)
        if isinstance(objs[p], list):
            objs[p].append(objs[i])
        else:
            objs[p][rng.randrange(1 << 20)] = objs[i]

    # live: extra edges (cycles, cross links, deeper graphs)
    for i in range(live):
        for _ in range(rng.randrange(0, 3)):
            x = rng.randrange(0, live)
            if x == i:
                continue
            if isinstance(objs[i], list):
                objs[i].append(objs[x])
            else:
                objs[i][rng.randrange(1 << 20)] = objs[x]

    # garbage: cycles among [live, n); not referenced from the live part
    j = live
    while j < n:
        k = min(j + 1, n - 1)
        if k == j:
            # odd tail: self loop keeps it alive under refcounting
            if isinstance(objs[j], list):
                objs[j].append(objs[j])
            else:
                objs[j][0] = objs[j]
            j += 1
        else:
            if isinstance(objs[j], list):
                objs[j].append(objs[k])
            else:
                objs[j][0] = objs[k]
            if isinstance(objs[k], list):
                objs[k].append(objs[j])
            else:
                objs[k][0] = objs[j]
            j += 2

    idx_by_id = {id(o): i for i, o in enumerate(objs)}
    refs = []
    for o in objs:
        seen = set()
        row = []
        for x in gc.get_referents(o):
            xi = idx_by_id.get(id(x))
            if xi is None or xi in seen:
                continue
            seen.add(xi)
            row.append(xi)
        refs.append(row)

    return {
        'objs': objs,
        'refs': refs,
        'root': idx_by_id[id(root)],
        'live': live,
        'n': n,
        'edges': sum(len(r) for r in refs),
    }


def bfs_marked(refs, root):
    marked = [0] * len(refs)
    q = [root]
    marked[root] = 1
    head = 0
    while head < len(q):
        c = q[head]
        head += 1
        for x in refs[c]:
            if not marked[x]:
                marked[x] = 1
                q.append(x)
    return marked


def graph_buffer(g, neg):
    n = g['n']
    refs = list(g['refs'])
    neg_victim = None
    if neg:
        # Deterministic injected fault: drop every out-edge of the root.
        # With live > 1 this always changes the reachable set, so the
        # comparison has a chance to catch it.
        neg_victim = g['root']
        refs[neg_victim] = []

    ref_base = (HDR_BASE + n * 16 + 0xFFF) & ~0xFFF
    offsets = [0] * n
    cur = ref_base
    for i in range(n):
        offsets[i] = cur
        cur += len(refs[i]) * 4 + 4
    if cur > GRAPH_SIZE:
        raise SystemExit('graph too large: %d > %d' % (cur, GRAPH_SIZE))

    buf = bytearray(cur)
    for i in range(n):
        o = HDR_BASE + i * 16
        struct.pack_into('<IIII', buf, o, i, len(refs[i]), GRAPH_BASE + offsets[i], 0)
    for i in range(n):
        o = offsets[i]
        for j, x in enumerate(refs[i]):
            struct.pack_into('<I', buf, o + j * 4, x)
        struct.pack_into('<I', buf, o + len(refs[i]) * 4, 0xFFFFFFFF)
    return bytes(buf), neg_victim


def run_host(g, neg):
    full = bfs_marked(g['refs'], g['root'])
    full_count = sum(full)
    print('SIDE_TABLE_HOST graph n=%d live=%d edges=%d root=%d reachable=%d garbage=%d'
          % (g['n'], g['live'], g['edges'], g['root'], full_count, g['n'] - full_count))

    # sanity: every live object is reachable, garbage is not
    bad = [i for i in range(g['live']) if not full[i]]
    if bad:
        print('SIDE_TABLE_HOST FAIL live-unreachable=%d first=%d' % (len(bad), bad[0]))
        return 1
    garb = [i for i in range(g['live'], g['n']) if full[i]]
    if garb:
        print('SIDE_TABLE_HOST FAIL garbage-reachable=%d first=%d' % (len(garb), garb[0]))
        return 1

    if neg:
        _, victim = graph_buffer(g, neg=True)
        corrupt_refs = [list(r) for r in g['refs']]
        corrupt_refs[victim] = []
        corrupt = bfs_marked(corrupt_refs, g['root'])
        if sum(corrupt) == full_count:
            print('SIDE_TABLE_HOST NEG-BAD victim=%d corruption did not change the mark set' % victim)
            return 1
        print('SIDE_TABLE_HOST NEG-OK victim=%d full=%d corrupt=%d'
              % (victim, full_count, sum(corrupt)))
        return 0

    print('SIDE_TABLE_HOST PASS n=%d reachable=%d' % (g['n'], full_count))
    return 0


def run_hw(g, neg, seed):
    full = bfs_marked(g['refs'], g['root'])
    full_count = sum(full)
    buf, victim = graph_buffer(g, neg)
    print('SIDE_TABLE_HW graph n=%d live=%d edges=%d root=%d reachable=%d garbage=%d seed=%d'
          % (g['n'], g['live'], g['edges'], g['root'], full_count, g['n'] - full_count, seed))
    if neg:
        print('SIDE_TABLE_HW negative control: victim=%d ref_count forced to 0' % victim)

    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    regs = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=REG_BASE)
    gph = mmap.mmap(fd, GRAPH_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=GRAPH_BASE)

    def rr(o):
        return struct.unpack_from('<I', regs, o)[0]

    def wr(o, v):
        struct.pack_into('<I', regs, o, v & 0xFFFFFFFF)

    mag, ver = rr(R_MAGIC), rr(R_VERSION)
    if mag != MAGIC_VALUE or ver != VERSION_VALUE:
        print('SIDE_TABLE_HW FAIL MAGIC=0x%08X VERSION=0x%08X (bitstream/software mismatch)' % (mag, ver))
        regs.close(); gph.close(); os.close(fd)
        return 2

    gph[0:len(buf)] = buf
    time.sleep(0.02)

    wr(R_ROOT_LIST, g['root'])
    wr(R_ROOT_COUNT, 1)
    wr(R_OBJ_BASE, GRAPH_BASE)
    wr(R_OBJ_COUNT, g['n'])
    wr(R_CTRL, CTRL_WR_MARK | CTRL_CLEAR_Q)
    time.sleep(0.002)
    wr(R_CTRL, CTRL_WR_MARK | CTRL_START)
    _ = rr(R_CTRL)                     # flush the posted START write
    time.sleep(0.0002)

    t0 = time.time()
    ran = False
    while time.time() < t0 + 3.0:
        if rr(R_CTRL) & CTRL_DONE:
            ran = True
            break
        time.sleep(0.0002)

    # Phase 2: the free-list scanner borrows the bitmap read port after DONE.
    free_deadline = t0 + 3.0
    while time.time() < free_deadline:
        if (rr(R_STATUS) & 0x20) == 0:
            break
        time.sleep(0.0002)
    free_count = rr(R_FREE_COUNT)
    free_ids = [rr(R_FREE_DATA) & 0xFFF for _ in range(free_count)]

    hw_marked = rr(R_MARKED)
    hw_cycles = rr(R_CYCLES)
    status_raw = rr(R_STATUS)
    q_tail = rr(R_Q_TAIL)
    exp_free = [i for i in range(g['n']) if not full[i]]

    bm_bad = 0
    bm_first = -1
    for o in range(g['n']):
        wr(R_BM_ADDR, o)
        rr(R_BM_ADDR)
        hb = (rr(R_BM_DATA) >> (o & 31)) & 1
        if hb != full[o]:
            bm_bad += 1
            if bm_first < 0:
                bm_first = o

    fails = []
    if not ran:
        fails.append('NO-RUN')
    if status_raw & 0xF:
        fails.append('STATUS=0x%X' % (status_raw & 0xF))
    if not ((status_raw >> 4) & 1):
        fails.append('NOT-IDLE')
    if hw_cycles < MIN_CYCLES:
        fails.append('CYCLES<%d' % MIN_CYCLES)
    if not neg and q_tail != (hw_marked & 0xFFF):
        fails.append('QTAIL=%d!=%d' % (q_tail, hw_marked & 0xFFF))
    if not neg and bm_bad:
        fails.append('BITMAP=%d first=%d' % (bm_bad, bm_first))
    if not neg and hw_marked != full_count:
        fails.append('MARKED=%d!=%d' % (hw_marked, full_count))
    if free_count != len(exp_free):
        fails.append('FREE_COUNT=%d!=%d' % (free_count, len(exp_free)))
    if sorted(free_ids) != exp_free:
        fails.append('FREE_SET')

    if neg:
        # The corrupted graph must produce a different count or a different set.
        neg_detected = (hw_marked != full_count) or bm_bad > 0 or \
                       (free_count != len(exp_free)) or (sorted(free_ids) != exp_free)
        print('SIDE_TABLE_HW neg marked=%d oracle=%d free=%d/%d bitmap_bad=%d status=0x%X cycles=%d'
              % (hw_marked, full_count, free_count, len(exp_free), bm_bad, status_raw & 0xF, hw_cycles))
        if neg_detected and ran and not (status_raw & 0xF):
            print('SIDE_TABLE_HW NEG-OK')
            rc = 0
        else:
            print('SIDE_TABLE_HW NEG-BAD (comparison did not detect the injected fault)')
            rc = 1
    else:
        ok = (len(fails) == 0)
        if ok:
            print('SIDE_TABLE_HW PASS marked=%d free=%d cycles=%d qtail=%d'
                  % (hw_marked, free_count, hw_cycles, q_tail))
            rc = 0
        else:
            print('SIDE_TABLE_HW FAIL ' + ' '.join(fails) +
                  ' (marked=%d free=%d cycles=%d qtail=%d)'
                  % (hw_marked, free_count, hw_cycles, q_tail))
            rc = 1

    regs.close(); gph.close(); os.close(fd)
    return rc


def selftest():
    ok = True
    for n in (1, 2, 3, 16, 64, 512):
        g = build_container_graph(n, 12345 + n)
        marked = bfs_marked(g['refs'], g['root'])
        live = g['live']
        if any(not marked[i] for i in range(live)):
            print('SELFTEST FAIL n=%d live-unreachable' % n)
            ok = False
        if any(marked[i] for i in range(live, n)):
            print('SELFTEST FAIL n=%d garbage-reachable' % n)
            ok = False
        buf, _ = graph_buffer(g, neg=False)
    print('SIDE_TABLE_SELFTEST %s' % ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


def main():
    opts = parse_args(sys.argv[1:])
    if opts['selftest']:
        return selftest()
    g = build_container_graph(opts['n'], opts['seed'])
    if opts['mode'] == 'hw':
        return run_hw(g, opts['neg'], opts['seed'])
    return run_host(g, opts['neg'])


if __name__ == '__main__':
    sys.exit(main())