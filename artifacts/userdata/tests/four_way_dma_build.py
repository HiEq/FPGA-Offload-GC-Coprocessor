#!/usr/bin/env python3
# four_way_dma_build.py - project four-way comparison, but the graph is built
# by cached C + PL330 DMA (dma_build_one) instead of fpga_gc_build_graph().
#
# Same columns as board/tools/tests/fpga_vs_c_vs_python.py, plus build_ms and
# e2e_ms = build_ms + HW_us/1000.  The marking numbers must match exactly.
import argparse
import mmap
import os
import struct
import subprocess
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


def _find_build_one():
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.environ.get('DMA_BUILD_ONE'),
        '/tmp/dma_build_one',
        os.path.join(here, 'bin', 'dma_build_one'),
        os.path.join(here, '..', 'bin', 'dma_build_one'),
        '/run/media/USERDATA-mmcblk0p2/bin/dma_build_one',
    ]
    for p in candidates:
        if p and os.path.exists(p):
            return p
    return '/tmp/dma_build_one'


BUILD_ONE = _find_build_one()


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


def dma_build(n, avg_refs):
    out = subprocess.check_output([BUILD_ONE, str(n), str(avg_refs)],
                                  text=True)
    for line in out.splitlines():
        if line.startswith('DMA_BUILD_ONE '):
            kv = {}
            for item in line.split()[1:]:
                k, v = item.split('=', 1)
                kv[k] = v
            return {k: float(v) if '.' in v else int(v) for k, v in kv.items()}
    raise RuntimeError('DMA_BUILD_ONE line missing: %r' % out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sizes', default='10,50,100,500,1000,2000,4000')
    ap.add_argument('--avg-refs', type=int, default=3)
    args = ap.parse_args()
    sizes = [int(s) for s in args.sizes.split(',') if s.strip()]

    if not os.path.exists(BUILD_ONE):
        raise SystemExit('%s missing (push dma_build_one)' % BUILD_ONE)
    if not os.path.exists('/dev/fogccc_dma'):
        raise SystemExit('/dev/fogccc_dma missing (insmod fogccc_dma.ko)')

    with fogccc.FOGCCC() as fpga:
        print(' %8s %5s %9s %9s %9s %9s %8s %6s %6s %6s %9s  %s'
              % ('objects', 'mkd', 'build ms', 'HW us', 'C-u us', 'C-c us',
                 'Py ms', 'Cu/HW', 'Cc/HW', 'Py/HW', 'e2e ms', 'verdict'))
        print(' %s' % ('-' * 112))

        fails = 0
        rows = []
        for n in sizes:
            b = dma_build(n, args.avg_refs)
            # The DMA path wrote the bytes; tell the C driver how many objects
            # are valid.  fpga._dev is the same fpga_gc_t used by the binding.
            fpga._dev.obj_count = n
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
            e2e = b['total_ms'] + hw_us / 1000.0
            rows.append((n, b['total_ms'], hw_us, e2e, ok))
            print(' %8d %5d %9.3f %9.1f %9.1f %9.1f %9.3f %6.1fx %6.1fx %6.0fx %9.3f  %s'
                  % (n, hw['marked'], b['total_ms'], hw_us, c_us, cc_us, p_ms,
                     c_us / hw_us if hw_us else 0.0,
                     cc_us / hw_us if hw_us else 0.0,
                     (p_ms * 1e3) / hw_us if hw_us else 0.0,
                     e2e, 'OK' if ok else '**MISMATCH**'))

    print()
    print(' DMA build = cached C graph (srand 42) + coherent staging + PL330 DMA;')
    print(' HW us = engine cycles only; C-u/C-c/Py are the same four-way references.')
    print(' e2e ms = DMA build total_ms + HW_us/1000 (no PS init/poll overhead).')
    r4000 = [r for r in rows if r[0] == 4000]
    if r4000:
        n, build_ms, hw_us, e2e, _ = r4000[0]
        # report reference: Python per-word build 102.2 ms + 645.4 us engine
        ref = 102.2 + 0.6454
        print(' N=4000: dma_build=%.3f ms  hw=%.3f ms  e2e=%.3f ms  '
              'paper_python_e2e=%.3f ms  speedup=%.1fx'
              % (build_ms, hw_us / 1000.0, e2e, ref, ref / e2e))
    print('THREE_WAY_RESULT %s' % ('OK' if fails == 0 else 'FAIL:%d' % fails))
    print('DMA_FOUR_WAY_RESULT %s' % ('OK' if fails == 0 else 'FAIL:%d' % fails))
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
