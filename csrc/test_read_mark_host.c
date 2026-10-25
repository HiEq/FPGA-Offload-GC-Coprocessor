/* ============================================================
 * test_read_mark_host.c - the real fpga_gc_read_mark() against a fake register block
 *
 *   gcc -O2 -Wall -Wextra -Werror -o test_read_mark_host \
 *       csrc/test_read_mark_host.c csrc/fpga_gc.c && ./test_read_mark_host
 *
 * Why: fpga_gc_read_mark() returns 0xFFFFFFFF when it cannot trust the probe.
 * That sentinel is what fogccc.barrier_verify() must treat as "unverified", and
 * on the board the "engine not idle" state cannot be forced deterministically.
 * Here the register block is a plain array, so STATUS can be set to any value.
 *
 *   READ_MARK_RESULT OK
 * ============================================================ */
#include <stdio.h>
#include <string.h>

#include "fpga_gc.h"

static uint32_t regs[1024];
static int failures;

static void check(const char *what, unsigned long got, unsigned long want) {
    if (got == want) {
        printf("ok   %-46s = 0x%lX\n", what, got);
        return;
    }
    printf("FAIL %-46s = 0x%lX, want 0x%lX\n", what, got, want);
    failures++;
}

int main(void) {
    fpga_gc_t dev;
    memset(&dev, 0, sizeof dev);
    dev.regs = regs;

    /* 1. engine neither idle nor scanning -> sentinel, and no probe write */
    memset(regs, 0, sizeof regs);
    regs[REG_STATUS / 4] = 0;
    check("busy engine -> sentinel", fpga_gc_read_mark(&dev, 7), 0xFFFFFFFFUL);
    check("busy engine -> BM_ADDR untouched", regs[REG_BM_ADDR / 4], 0);

    /* 2. idle, bit set -> 1, and the probe address is written */
    memset(regs, 0, sizeof regs);
    regs[REG_STATUS / 4] = STATUS_IDLE;
    regs[REG_BM_DATA / 4] = (1U << 3);
    check("idle, bit set -> 1", fpga_gc_read_mark(&dev, 3), 1);
    check("idle -> BM_ADDR = obj id", regs[REG_BM_ADDR / 4], 3);

    /* 3. idle, bit clear -> 0 */
    check("idle, bit clear -> 0", fpga_gc_read_mark(&dev, 4), 0);

    /* 4. out-of-range id -> 0, probe untouched (no sentinel) */
    regs[REG_BM_ADDR / 4] = 0xFFFF;
    check("id 4096 -> 0", fpga_gc_read_mark(&dev, 4096), 0);
    check("id 4096 -> BM_ADDR untouched", regs[REG_BM_ADDR / 4], 0xFFFF);

    /* 5. a different bit position in the same word */
    memset(regs, 0, sizeof regs);
    regs[REG_STATUS / 4] = STATUS_IDLE;
    regs[REG_BM_DATA / 4] = (1U << 31);
    check("bit 31 set -> 1", fpga_gc_read_mark(&dev, 31), 1);
    check("bit 31 set, bit 30 -> 0", fpga_gc_read_mark(&dev, 30), 0);

    printf("READ_MARK_RESULT %s\n", failures ? "FAIL" : "OK");
    return failures ? 1 : 0;
}
