#!/usr/bin/env python3
# ============================================================
# fpga_vs_c_vs_python.py - mark ONE graph with four implementations
#
#   FPGA : the PL engine (CYCLES / 100 MHz, engine time only)
#   C-u  : fpga_gc_sw_mark(), same graph, uncached DDR
#   C-c  : fpga_gc_sw_mark_cached(), same BFS on a heap copy
#          (the copy is not timed; this is the CPU upper bound)
#   Py   : a plain Python BFS over /dev/mem, one read per reference
#
# The graph is built once per size, so all four numbers describe the same
# object graph.  All four counts must equal the C oracle.
#
#   usage: python3 tests/fpga_vs_c_vs_python.py [--sizes 10,50,...,4000] [--avg-refs 3]
# ============================================================
import argparse
import gc
import mmap
import os
import struct
import sys
import time


# ---- 运行日志：stdout/stderr 同时写入 logs/<项目>_<时间>.log ----
class _Tee(object):
    def __init__(self, *streams):
        self._streams = streams

    def write(self, data):
        for s in self._streams:
            s.write(data)
        return len(data)

    def flush(self):
        for s in self._streams:
            s.flush()


def _start_log(tag, script_file):
    d = os.path.dirname(os.path.abspath(script_file))
    base = os.path.dirname(d) if os.path.basename(d) == 'tests' else d
    logs = os.path.join(base, 'logs')
    try:
        os.makedirs(logs, exist_ok=True)
        f = open(os.path.join(logs, '%s_%s.log'
                              % (tag, time.strftime('%Y%m%d_%H%M%S'))),
                 'w', encoding='utf-8')
    except OSError:
        return None
    sys.stdout = _Tee(sys.__stdout__, f)
    sys.stderr = _Tee(sys.__stderr__, f)
    return f.name

LOG_PATH = _start_log('three_way', __file__)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'py'))
import fogccc  # noqa: E402

GRAPH_BASE = 0x1E000000
GRAPH_SIZE = 0x100000
TERMINATOR = 0xFFFFFFFF
MAX_OBJECTS = 4096


def py_mark(n, base):
    """BFS over the DDR image; returns the number of reachable objects."""
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
    gc.disable()   # keep interpreter pauses out of the C/Py timings

    with fogccc.FOGCCC() as fpga:
        print(' %8s %5s %9s %9s %9s %8s %6s %6s %6s  %s'
              % ('objects', 'mkd', 'HW us', 'C-u us', 'C-c us', 'Py ms',
                 'Cu/HW', 'Cc/HW', 'Py/HW', 'verdict'))
        print(' %s' % ('-' * 88))

        fails = 0
        for n in sizes:
            fpga.build_graph(n, args.avg_refs)
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
            print(' %8d %5d %9.1f %9.1f %9.1f %8.3f %6.1fx %6.1fx %6.0fx  %s'
                  % (n, hw['marked'], hw_us, c_us, cc_us, p_ms,
                     c_us / hw_us if hw_us else 0.0,
                     cc_us / hw_us if hw_us else 0.0,
                     (p_ms * 1e3) / hw_us if hw_us else 0.0,
                     'OK' if ok else '**MISMATCH**'))

    print()
    print(' FPGA us = engine cycles only; C-u us = in-process C BFS on the same '
          'uncached DDR graph;')
    print(' C-c us  = same BFS on a heap copy (cache-resident bound, copy not '
          'timed); Py ms = interpreter BFS.')
    print('THREE_WAY_RESULT %s' % ('OK' if fails == 0 else 'FAIL:%d' % fails))
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
