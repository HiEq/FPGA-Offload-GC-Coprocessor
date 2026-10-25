#!/usr/bin/env python3
# ============================================================
# barrier_verify_test.py - checks fogccc.barrier_verify() on the board
#
#   python3 barrier_verify_test.py  -> BARRIER_VERIFY_RESULT OK
#
# The binding's barrier_verify(ids) is the "verify the barrier's effect" backstop:
# all targets marked -> the epoch can be treated as exact, anything else must fall
# back to a full mark.  It must therefore report False for an unmarked target, and
# it must NOT accept the 0xFFFFFFFF probe-failure sentinel as a mark (that case is
# covered by the host unit test tests/test_fogccc_binding.py; it cannot be forced
# on the card without stalling the engine).
#
# Checks
#   1. every id of the live set reads back marked      -> True
#   2. an object outside the live set                  -> False
#   3. the decision uses read_mark() == 1, not truthiness (source check, so a
#      regression to ``all(read_mark(i) ...)`` fails here too)
# ============================================================
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join('/run/media/USERDATA-mmcblk0p2', 'py'),
           os.path.join(HERE, '..', '..', 'python'),
           os.path.join(HERE, '..', 'python'),
           os.path.join(HERE, '..', '..', 'artifacts', 'userdata', 'py')):
    if os.path.exists(os.path.join(_p, 'fogccc.py')):
        sys.path.insert(0, _p)
        break
import fogccc  # noqa: E402

N = 256
fails = []


def main():
    with fogccc.FOGCCC() as fpga:
        fpga.build_graph(N, avg_refs=3)
        fpga.set_roots([0])
        oracle = fpga.mark_sw([0])
        res = fpga.mark()
        marks = fpga.dump_marks(N)
        live = sorted(i for i in range(N) if marks[i] == 1)
        unmarked = [i for i in range(1, N) if marks[i] != 1]
        print('full mark : marked=%d oracle=%d live=%d unmarked=%d'
              % (res['marked'], oracle, len(live), len(unmarked)))
        if res['marked'] != oracle:
            fails.append('oracle')

        # 1) all live ids verify True
        sample = live[:16]
        ok = fpga.barrier_verify(sample)
        print('marked    : %d ids -> %s (expect True)' % (len(sample), ok))
        if not ok:
            fails.append('marked')

        # 2) an unmarked object verifies False
        if not unmarked:
            fails.append('no-unmarked-target')
            print('FAIL: the graph has no unmarked object to use as a negative control')
        else:
            bad = fpga.barrier_verify([unmarked[0]])
            print('unmarked  : id %d -> %s (expect False)' % (unmarked[0], bad))
            if bad:
                fails.append('unmarked')

        # 3) mixed: one marked + one unmarked must be False
        if unmarked:
            mixed = fpga.barrier_verify([live[0], unmarked[0]])
            print('mixed     : %s (expect False)' % mixed)
            if mixed:
                fails.append('mixed')

        # 4) the decision compares to 1, so the probe sentinel cannot pass
        src = open(os.path.join(os.path.dirname(fogccc.__file__), 'fogccc.py'),
                   encoding='utf-8').read()
        if 'read_mark(int(i)) == 1' not in src:
            print('FAIL: barrier_verify does not compare the probe result to 1')
            fails.append('sentinel-guard')

    print('BARRIER_VERIFY_RESULT %s' % ('OK' if not fails else 'FAIL:' + ','.join(fails)))
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.exit(main())
