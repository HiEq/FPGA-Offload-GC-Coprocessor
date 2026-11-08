#!/usr/bin/env python3
"""Fail the build if a memory array was dissolved out of BRAM.

Usage:  python tools/check_bram.py <vivado.log> <utilization.rpt>
        [--max-ff N] [--max-lutram N] [--min-bram N]

Catches, in order of how early they show up:
  1. "[Synth 8-6849] Infeasible attribute ram_style = \"block\""  -> the
     memory was pushed into LUTRAM (this is what a conditional read or a
     bypass inside the memory block does).
  2. "[Synth 8-3391] Unable to infer a block/distributed RAM"      -> the
     array could not be inferred at all.
  3. Register count above --max-ff (default 40000)                 -> the array
     was dissolved into flip-flops.
  4. LUT-as-memory above --max-lutram (default 12000)              -> too much
     distributed RAM, i.e. something that should be BRAM is not.
  5. BRAM below --min-bram                                          -> a memory
     that is expected to be there is missing.

Exit code 0 = clean, 1 = a violation was found.
"""
import re
import sys


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    log_path, util_path = argv[1], argv[2]
    max_ff, max_lutram, min_bram = 40000, 12000, 0
    i = 3
    while i < len(argv):
        if argv[i] == "--max-ff":
            max_ff = int(argv[i + 1]); i += 2
        elif argv[i] == "--max-lutram":
            max_lutram = int(argv[i + 1]); i += 2
        elif argv[i] == "--min-bram":
            min_bram = int(argv[i + 1]); i += 2
        else:
            print("unknown option", argv[i])
            return 2

    bad = []

    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        log = f.read()

    if '8-6849' in log and "Infeasible attribute ram_style" in log:
        for line in log.splitlines():
            if "Infeasible attribute ram_style" in line:
                bad.append(line.strip())

    for line in log.splitlines():
        if "8-3391" in line:
            bad.append(line.strip())

    ff = lutram = bram = None
    with open(util_path, "r", encoding="utf-8", errors="replace") as f:
        util = f.read()

    m = re.search(r"\|\s*Slice Registers\s*\|\s*(\d+)", util)
    if m:
        ff = int(m.group(1))
    m = re.search(r"\|\s*LUT as Memory\s*\|\s*(\d+)", util)
    if m:
        lutram = int(m.group(1))
    m = re.search(r"\|\s*Block RAM Tile\s*\|\s*(\d+)", util)
    if m:
        bram = int(m.group(1))

    print("check_bram: FF=%s LUTRAM=%s BRAM=%s (limits FF<=%d LUTRAM<=%d BRAM>=%d)"
          % (ff, lutram, bram, max_ff, max_lutram, min_bram))

    if ff is None or lutram is None or bram is None:
        bad.append("utilization report is missing FF/LUTRAM/BRAM rows")

    if ff is not None and ff > max_ff:
        bad.append("FF=%d > %d: an array was dissolved into flip-flops" % (ff, max_ff))
    if lutram is not None and lutram > max_lutram:
        bad.append("LUT-as-memory=%d > %d: something that should be BRAM is distributed RAM"
                   % (lutram, max_lutram))
    if bram is not None and bram < min_bram:
        bad.append("BRAM=%d < %d: expected memory is missing" % (bram, min_bram))

    if bad:
        print("")
        print("BRAM CHECK FAILED:")
        for b in bad:
            print("  -", b)
        return 1

    print("BRAM CHECK OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
