#!/usr/bin/env python3
# ============================================================
# verify_bootbin.py - structural check of a repacked BOOT.BIN
#
#   python3 verify_bootbin.py <new BOOT.BIN> <reference BOOT.BIN> <new bitstream> <reference bitstream>
#
# bootgen does not store the .bit verbatim (it converts the .bit to the raw
# bitstream), so identity is established in three steps:
#   1. determinism: re-running this recipe with the REFERENCE bitstream must
#      reproduce the REFERENCE BOOT.BIN byte-for-byte (done with bootgen
#      separately; see tools/out/bootbin_repack_*.log).
#   2. this script: same size, and the boot-header/FSBL region and the
#      U-Boot/DTB region are byte-identical to the reference -> the only
#      changed bytes are in the bitstream partition.
#   3. cold-boot functional test: the bitstream identity is decided by the
#      Phase-2 free-list checks on the board (fixed build: free = n - live;
#      the pre-fix layout bug gave a different count).
# ============================================================
import hashlib
import sys


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        return 2
    newb, refb, newbit_p, refbit_p = sys.argv[1:5]
    newB = open(newb, 'rb').read()
    refB = open(refb, 'rb').read()
    newT = open(newbit_p, 'rb').read()
    refT = open(refbit_p, 'rb').read()
    fail = False
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
        print('FAIL: images are identical (was the new bitstream used?)')
        return 1
    lo_b, hi_b = diffs[0], diffs[-1]
    lo = next(i for i in range(lo_b, min(lo_b + bs, n)) if refB[i] != newB[i])
    hi = next(i for i in range(min(hi_b + bs, n) - 1, hi_b - 1, -1) if refB[i] != newB[i])
    span = hi - lo + 1
    print('diff blocks (64 KiB): %d of %d in the changed span' % (len(diffs), (hi_b - lo_b) // bs + 1))
    print('changed span: %d (0x%X) .. %d, %d bytes   (bitstream length %d, delta %d)'
          % (lo, lo, hi, span, len(newT), span - len(newT)))
    print('unchanged head: %d bytes (boot header + FSBL region)' % lo)
    print('unchanged tail: %d bytes (U-Boot + DTB region)' % (n - hi - 1))

    if lo < 0x40000:
        print('FAIL changes reach into the first 256 KiB (FSBL region)')
        fail = True
    if (n - hi - 1) < 0x100000:
        print('FAIL changes reach into the last 1 MiB (U-Boot/DTB region)')
        fail = True
    if abs(span - len(newT)) > len(newT) // 10:
        print('FAIL changed span deviates from the bitstream length by >10%%')
        fail = True
    if fail:
        print('FAIL verify_bootbin')
        return 1
    print('PASS verify_bootbin (only the bitstream partition changed)')
    return 0


if __name__ == '__main__':
    sys.exit(main())