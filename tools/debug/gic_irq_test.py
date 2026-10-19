#!/usr/bin/env python3
# ============================================================
# gic_irq_test.py - does irq_o (PL done) actually reach the PS GIC?
#
# gc_top.irq_o = w_done, wired to ps7_0/IRQ_F2P -> GIC SPI 61.
# While done is high the GIC distributor marks the SPI pending, so we can
# read that state WITHOUT enabling the IRQ (enabling would cause an IRQ
# storm: the line is level-sensitive and stays high).
#
#   GICD @ 0xF8F01000 (Zynq-7000 distributor)
#     ISPENDR1  @ 0x204 -> SPI 32..63, bit 29 = SPI 61
#     ISENABLER1@ 0x104
#     IGROUPR1  @ 0x084    (0 = secure/group0, 1 = non-secure/group1)
#
# exit code: 0 = pending (irq reached the GIC), 1 = not pending
# ============================================================
import mmap, os, struct, sys

GICD_BASE = 0xF8F01000
SGI_SPI   = 61          # IRQ_F2P[0]
BIT       = SGI_SPI - 32

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
m  = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=GICD_BASE)

def rd(o): return struct.unpack_from('<I', m, o)[0]

en  = rd(0x104)
grp = rd(0x084)
pen = rd(0x204)

print("GICD @ 0x%08X   SPI %d (IRQ_F2P[0])" % (GICD_BASE, SGI_SPI))
print("  ISENABLER1 = 0x%08X   enabled = %d" % (en, (en >> BIT) & 1))
print("  IGROUPR1   = 0x%08X   group   = %d  (0=secure,1=non-secure)" % (grp, (grp >> BIT) & 1))
print("  ISPENDR1   = 0x%08X   PENDING = %d" % (pen, (pen >> BIT) & 1))
print("VERDICT: %s" % ("IRQ_REACHED_GIC" if ((pen >> BIT) & 1) else "NO_PENDING"))
sys.exit(0 if ((pen >> BIT) & 1) else 1)
