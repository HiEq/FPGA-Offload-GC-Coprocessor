#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Structural check of a repacked BOOT.BIN.

    python3 verify_bootbin.py <new BOOT.BIN> <reference BOOT.BIN> \\
        <new bitstream> <reference bitstream> [--head 0x40000] [--tail 0x100000]

bootgen does not store the .bit verbatim, so the image cannot be compared by
hash. This script proves that the only changed bytes sit in the bitstream
partition:

1. both images have the same size;
2. the changed byte span is inside the allowed window, i.e. it does not reach
   into the boot header/FSBL region at the start or the U-Boot/DTB region at
   the end;
3. the span length is within 10% of the new bitstream length.

The result is structural evidence, not a boot test. Boot the repacked image and
run the functional checks before publishing it.

Defaults (256 KiB head, 1 MiB tail) match a Zynq-7000 boot image with the FSBL
first and U-Boot plus device tree last; pass --head/--tail for another layout.
"""
import argparse
import hashlib
import sys


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument('new_boot')
    ap.add_argument('ref_boot')
    ap.add_argument('new_bit')
    ap.add_argument('ref_bit')
    ap.add_argument('--head', default='0x40000', help='protected head bytes')
    ap.add_argument('--tail', default='0x100000', help='protected tail bytes')
    a = ap.parse_args()
    head = int(a.head, 0)
    tail = int(a.tail, 0)

    newB = open(a.new_boot, 'rb').read()
    refB = open(a.ref_boot, 'rb').read()
    newT = open(a.new_bit, 'rb').read()
    refT = open(a.ref_bit, 'rb').read()

    for name, blob in (('new BOOT.BIN', newB), ('ref BOOT.BIN', refB),
                       ('new bitstream', newT), ('ref bitstream', refT)):
        print('%-14s %10d bytes  sha256 %s' % (name, len(blob), sha(blob)))

    if len(newB) != len(refB):
        print('FAIL sizes differ (%d vs %d)' % (len(newB), len(refB)))
        return 1
    if len(newT) != len(refT):
        print('NOTE bitstream sizes differ (%d vs %d)' % (len(newT), len(refT)))

    bs = 1 << 16
    n = len(newB)
    diffs = [o for o in range(0, n, bs) if refB[o:o + bs] != newB[o:o + bs]]
    if not diffs:
        print('FAIL images are identical (was the new bitstream used?)')
        return 1
    lo_b, hi_b = diffs[0], diffs[-1]
    lo = next(i for i in range(lo_b, min(lo_b + bs, n)) if refB[i] != newB[i])
    hi = next(i for i in range(min(hi_b + bs, n) - 1, hi_b - 1, -1)
              if refB[i] != newB[i])
    span = hi - lo + 1
    print('diff blocks (64 KiB): %d of %d in the changed span'
          % (len(diffs), (hi_b - lo_b) // bs + 1))
    print('changed span: %d (0x%X) .. %d, %d bytes   (bitstream length %d, delta %d)'
          % (lo, lo, hi, span, len(newT), span - len(newT)))
    print('unchanged head: %d bytes' % lo)
    print('unchanged tail: %d bytes' % (n - hi - 1))

    fail = False
    if lo < head:
        print('FAIL changes reach into the first %d bytes' % head)
        fail = True
    if (n - hi - 1) < tail:
        print('FAIL changes reach into the last %d bytes' % tail)
        fail = True
    if len(newT) and abs(span - len(newT)) > len(newT) // 10:
        print('FAIL changed span deviates from the bitstream length by >10%')
        fail = True
    if fail:
        print('FAIL verify_bootbin')
        return 1
    print('PASS verify_bootbin (only the bitstream partition changed)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
