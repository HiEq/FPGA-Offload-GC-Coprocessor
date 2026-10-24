#!/usr/bin/env python3
# ============================================================
# py_bfs.py - Python BFS reference (a script-level walk, not a runtime's GC:
#             struct.unpack_from over /dev/mem, one reference at a time)
#
# Marks the SAME object graph that test_main built in DDR, using a
# plain Python BFS.  It is a Python-LEVEL reference (interpreter loop +
# one uncached /dev/mem read per reference) and is only a magnitude
# context, not a same-stage baseline.
#
#   usage: python3 py_bfs.py <n> <graph_phys_hex> <root>
#   output: "<elapsed_ms> <marked_count>"
#
# Layout (must match csrc/fpga_gc.c):
#   object k header @ graph + k*16 : [id][ref_count][ref_array_phys][reserved]
#   ref array      @ ref_array_phys : [ref0][ref1]...[0xFFFFFFFF]
# ============================================================
import mmap
import os
import struct
import sys
import time

GRAPH_MAP_SIZE = 0x100000      # 1 MB, same as fpga_gc.h
TERMINATOR = 0xFFFFFFFF


def main():
    if len(sys.argv) != 4:
        sys.stderr.write("usage: py_bfs.py <n> <graph_phys_hex> <root>\n")
        return 2

    n = int(sys.argv[1])
    base = int(sys.argv[2], 0)
    root = int(sys.argv[3])

    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    m = None
    try:
        m = mmap.mmap(fd, GRAPH_MAP_SIZE, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=base)

        def u32(off):
            return struct.unpack_from('<I', m, off)[0]

        t0 = time.perf_counter()

        marked = bytearray(n)
        queue = [root]
        marked[root] = 1
        head = 0

        while head < len(queue):
            cur = queue[head]
            head += 1
            ref_count = u32(cur * 16 + 4)
            ref_off = u32(cur * 16 + 8) - base
            for j in range(ref_count):
                tgt = u32(ref_off + j * 4)
                if tgt == TERMINATOR:
                    break
                if tgt < n and not marked[tgt]:
                    marked[tgt] = 1
                    queue.append(tgt)

        elapsed_ms = (time.perf_counter() - t0) * 1000.0
    finally:
        if m is not None:
            m.close()
        os.close(fd)

    sys.stdout.write("%.3f %d\n" % (elapsed_ms, len(queue)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
