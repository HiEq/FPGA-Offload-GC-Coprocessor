#!/usr/bin/env python3
# four_way_c_build.py - project four-way comparison with the C graph builder.
# This is the original fpga_vs_c_vs_python.py flow plus a build_ms column and
# an e2e_ms = build_ms + HW_us/1000 column.
import argparse
import mmap
import os
import statistics
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
for p in ('/run/media/USERDATA-mmcblk0p2/py', '/mnt/userdata/py',
          os.path.join(HERE, 'py')):
    if os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)
import fogccc  # noqa: E402

GRAPH_BASE = 0x1E000000
GRAPH_SIZE = 0x100000
TERMINATOR = 0xFFFFFFFF
MAX_OBJECTS = 4096


def py_mark(n, base):
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    try:
        m = mmap.mmap(fd, GRAPH_SIZE, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=base)

        def u32(off):
            return struct.unpack_from('<I', m, off)[0]

        seen = {0}
        queue = [0]
        while queue:
            o = queue.pop()
            ref_count = u32(o * 16 + 4)
            ref_addr = u32(o * 16 + 8)
            if ref_count > MAX_OBJECTS:
                continue
            off = ref_addr - base
            for j in range(ref_count):
                r = u32(off + j * 4)
                if r == TERMINATOR or r >= n:
                    break
                if r not in seen:
                    seen.add(r)
                    queue.append(r)
        m.close()
        return len(seen)
    finally:
        os.close(fd)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sizes', default='10,50,100,500,1000,2000,4000')
    ap.add_argument('--avg-refs', type=int, default=3)
    args = ap.parse_args()
    sizes = [int(s) for s in args.sizes.split(',') if s.strip()]

    with fogccc.FOGCCC() as fpga:
        print(' %8s %5s %9s %9s %9s %9s %9s %8s %6s %6s %9s  %s'
              % ('objects', 'mkd', 'build ms', 'HW us', 'C-u us', 'C-c us',
                 'Py ms', 'Cu/HW', 'Cc/HW', 'Py/HW', 'e2e ms', 'verdict'))
        print(' %s' % ('-' * 112))

        fails = 0
        rows = []
        for n in sizes:
            bt = []
            for _ in range(5):
                t0 = time.perf_counter()
                fpga.build_graph(n, args.avg_refs)
                bt.append((time.perf_counter() - t0) * 1e3)
            build_ms = statistics.median(bt)
            fpga.set_roots([0])

            hw = fpga.mark()
            c_count, c_us = fpga.mark_sw_us([0], cached=False)
            cc_count, cc_us = fpga.mark_sw_us([0], cached=True)
            t0 = time.perf_counter()
            p_count = py_mark(n, GRAPH_BASE)
            p_ms = (time.perf_counter() - t0) * 1e3

            ok = (hw['marked'] == c_count == cc_count == p_count)
            if not ok:
                fails += 1
            hw_us = hw['hw_us']
            e2e = build_ms + hw_us / 1000.0
            rows.append((n, build_ms, hw_us, e2e, ok))
            print(' %8d %5d %9.3f %9.1f %9.1f %9.1f %9.3f %6.1fx %6.1fx %6.0fx %9.3f  %s'
                  % (n, hw['marked'], build_ms, hw_us, c_us, cc_us, p_ms,
                     c_us / hw_us if hw_us else 0.0,
                     cc_us / hw_us if hw_us else 0.0,
                     (p_ms * 1e3) / hw_us if hw_us else 0.0,
                     e2e, 'OK' if ok else '**MISMATCH**'))

    print()
    print(' C build = fpga_gc_build_graph() (direct uncached writes);')
    print(' HW us = engine cycles only; C-u/C-c/Py are the same four-way references.')
    print(' e2e ms = C build_ms + HW_us/1000 (no PS init/poll overhead).')
    r4000 = [r for r in rows if r[0] == 4000]
    if r4000:
        n, build_ms, hw_us, e2e, _ = r4000[0]
        ref = 102.2 + 0.6454
        print(' N=4000: c_build=%.3f ms  hw=%.3f ms  e2e=%.3f ms  '
              'paper_python_e2e=%.3f ms  speedup=%.1fx'
              % (build_ms, hw_us / 1000.0, e2e, ref, ref / e2e))
    print('THREE_WAY_RESULT %s' % ('OK' if fails == 0 else 'FAIL:%d' % fails))
    print('C_FOUR_WAY_RESULT %s' % ('OK' if fails == 0 else 'FAIL:%d' % fails))
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
