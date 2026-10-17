#!/usr/bin/env python3
# Dump the GIC state for SPI 61 (IRQ_F2P[0]) - debug helper
import mmap, os, struct

GICD, GICC = 0xF8F01000, 0xF8F00000
SPI = 61

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
d = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=GICD)
c = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=GICC)
OFF = 0x100  # GICC base is not page aligned

def rd(m, o, fmt='<I'):
    return struct.unpack_from(fmt, m, o)[0]

print("SPI %d" % SPI)
print("  GICD_CTLR      = 0x%08X" % rd(d, 0x000))
print("  ISENABLER1     = 0x%08X  en=%d" % (rd(d, 0x104), (rd(d, 0x104) >> (SPI - 32)) & 1))
print("  IGROUPR1       = 0x%08X  grp=%d" % (rd(d, 0x084), (rd(d, 0x084) >> (SPI - 32)) & 1))
print("  ITARGETSR[%d]  = 0x%02X" % (SPI, rd(d, 0x800 + SPI, '<B')))
icfgr = rd(d, 0xC00 + 4 * (SPI // 4))
print("  ICFGR[%d]      = 0x%08X  (bits %d:%d = %d, 0=level 1=edge)" %
      (SPI // 4, icfgr, (SPI % 4) * 2 + 1, (SPI % 4) * 2, (icfgr >> ((SPI % 4) * 2)) & 3))
print("  IPRIORITY[%d]  = 0x%02X" % (SPI, rd(d, 0x400 + SPI, '<B')))
print("  ISPENDR1       = 0x%08X  pend=%d" % (rd(d, 0x204), (rd(d, 0x204) >> (SPI - 32)) & 1))
print("  GICC_CTLR      = 0x%08X" % rd(c, 0x00 + OFF))
print("  GICC_PMR       = 0x%08X" % rd(c, 0x04 + OFF))
print("  GICC_IAR       = 0x%08X" % rd(c, 0x0C + OFF))
print("  GICC_RPR       = 0x%08X" % rd(c, 0x14 + OFF))
print("  GICC_HPPIR     = 0x%08X" % rd(c, 0x18 + OFF))
