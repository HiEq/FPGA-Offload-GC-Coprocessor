// ============================================================
// test_main.c — FOGCCC 测试主程序
//
// 测试内容:
//   Test 1: 正确性 + 性能 (多种规模)
//   Test 2: 循环图 (含环)
//   Test 3: 重复执行一致性 (100次)
//
// 编译: gcc -O2 -o test_fpga fpga_gc.c test_main.c -lrt
// 运行: sudo ./test_fpga
// ============================================================
#include "fpga_gc.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>

// 纳秒差转微秒
static double elapsed_us(struct timespec *t0, struct timespec *t1) {
    return (t1->tv_sec - t0->tv_sec) * 1e6 +
           (t1->tv_nsec - t0->tv_nsec) / 1e3;
}

// ============================================================
// Test 1: 正确性 + 性能
// ============================================================
static int test_correctness(fpga_gc_t *dev) {
    printf("\n");
    printf("=============================================\n");
    printf("  Test 1: Correctness & Performance\n");
    printf("=============================================\n");
    printf("%-8s %-10s %-10s %-13s %-13s %-7s %-9s\n",
           "Objects", "FPGA", "SW", "SW Time(us)", "FPGA Time(us)",
           "Match", "Speedup");
    printf("-------- ---------- ---------- ------------- ------------- "
           "------- ---------\n");

    int sizes[] = {10, 50, 100, 500, 1000, 2000, 4000};
    int n_sizes = (int)(sizeof(sizes) / sizeof(sizes[0]));
    int all_pass = 1;

    for (int s = 0; s < n_sizes; s++) {
        int n = sizes[s];

        // 构建图
        if (fpga_gc_build_graph(dev, n, 3) < 0) continue;

        // 设置根集
        uint32_t roots[] = {0};
        fpga_gc_set_roots(dev, roots, 1);

        // 软件标记 (基准)
        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        uint32_t sw_count = fpga_gc_sw_mark(dev, roots, 1);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double sw_us = elapsed_us(&t0, &t1);

        // FPGA标记
        clock_gettime(CLOCK_MONOTONIC, &t0);
        uint32_t cycles = 0;
        uint32_t fpga_count = fpga_gc_mark(dev, &cycles);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double fpga_us = elapsed_us(&t0, &t1);

        // 结果
        int match = (fpga_count == sw_count);
        double speedup = (fpga_us > 0) ? sw_us / fpga_us : 0;

        printf("%-8d %-10u %-10u %-13.1f %-13.1f %-7s %6.2fx%s\n",
               n, fpga_count, sw_count, sw_us, fpga_us,
               match ? "PASS" : "FAIL", speedup,
               match ? "" : "  <<<< MISMATCH");

        if (!match) all_pass = 0;
    }

    printf("  Result: %s\n", all_pass ? "ALL PASS" : "SOME FAILED");
    return all_pass;
}

// ============================================================
// Test 2: 循环图 (含环)
//
// 图结构:
//   0 → 1 → 2 → 0   (环: 0,1,2互相可达)
//   3 → 1            (对象3可达环)
//   4 → (无引用)      (对象4孤立, 不可达)
//
// 根集 = {0, 3}
// 预期标记 = {0,1,2,3} = 4个 (对象4不可达)
// ============================================================
static int test_cycle(fpga_gc_t *dev) {
    printf("\n");
    printf("=============================================\n");
    printf("  Test 2: Cycle Graph\n");
    printf("=============================================\n");

    int n = 5;
    if (fpga_gc_build_graph(dev, n, 2) < 0) return 0;

    // 手动覆盖图结构
    uint8_t *base = (uint8_t *)dev->graph_vaddr;
    uint32_t paddr = dev->graph_paddr;
    uint32_t REF_BASE = 0x1000;

    // 对象0: 引用{1}
    *(uint32_t *)(base + 0*16 + 1) = 1;          // ref_count
    *(uint32_t *)(base + 0*16 + 2) = paddr + REF_BASE; // ref_addr
    *(uint32_t *)(base + REF_BASE + 0) = 1;
    *(uint32_t *)(base + REF_BASE + 4) = 0xFFFFFFFF;

    // 对象1: 引用{2}
    *(uint32_t *)(base + 1*16 + 1) = 1;
    *(uint32_t *)(base + 1*16 + 2) = paddr + REF_BASE + 8;
    *(uint32_t *)(base + REF_BASE + 8)  = 2;
    *(uint32_t *)(base + REF_BASE + 12) = 0xFFFFFFFF;

    // 对象2: 引用{0} (形成环!)
    *(uint32_t *)(base + 2*16 + 1) = 1;
    *(uint32_t *)(base + 2*16 + 2) = paddr + REF_BASE + 16;
    *(uint32_t *)(base + REF_BASE + 16) = 0;
    *(uint32_t *)(base + REF_BASE + 20) = 0xFFFFFFFF;

    // 对象3: 引用{1}
    *(uint32_t *)(base + 3*16 + 1) = 1;
    *(uint32_t *)(base + 3*16 + 2) = paddr + REF_BASE + 24;
    *(uint32_t *)(base + REF_BASE + 24) = 1;
    *(uint32_t *)(base + REF_BASE + 28) = 0xFFFFFFFF;

    // 对象4: 无引用 (孤立)
    *(uint32_t *)(base + 4*16 + 1) = 0;
    *(uint32_t *)(base + 4*16 + 2) = paddr + REF_BASE + 32;
    *(uint32_t *)(base + REF_BASE + 32) = 0xFFFFFFFF;

    // 根集 = {0, 3}
    uint32_t roots[] = {0, 3};
    fpga_gc_set_roots(dev, roots, 2);

    // 软件标记
    uint32_t sw_count = fpga_gc_sw_mark(dev, roots, 2);

    // FPGA标记
    uint32_t cycles = 0;
    uint32_t fpga_count = fpga_gc_mark(dev, &cycles);

    int expected = 4;  // {0,1,2,3} 可达, {4} 不可达
    int pass = (fpga_count == (uint32_t)expected) &&
               (sw_count == (uint32_t)expected);

    printf("  Graph: 0→1→2→0 (cycle), 3→1, 4 (isolated)\n");
    printf("  Roots: {0, 3}\n");
    printf("  Expected: %d  SW: %u  FPGA: %u  => %s\n",
           expected, sw_count, fpga_count,
           pass ? "PASS" : "FAIL");
    return pass;
}

// ============================================================
// Test 3: 重复执行一致性
// ============================================================
static int test_repeat(fpga_gc_t *dev) {
    printf("\n");
    printf("=============================================\n");
    printf("  Test 3: Repeat Consistency (100 runs)\n");
    printf("=============================================\n");

    int n = 1000;
    if (fpga_gc_build_graph(dev, n, 3) < 0) return 0;

    uint32_t roots[] = {0};
    fpga_gc_set_roots(dev, roots, 1);

    uint32_t ref_count = 0;
    uint32_t min_cycles = 0xFFFFFFFF, max_cycles = 0;
    int pass = 1;

    for (int i = 0; i < 100; i++) {
        uint32_t cycles = 0;
        uint32_t count = fpga_gc_mark(dev, &cycles);

        if (i == 0) {
            ref_count = count;
        } else if (count != ref_count) {
            printf("  Run %d: count mismatch %u != %u\n",
                   i, count, ref_count);
            pass = 0;
        }

        if (cycles < min_cycles) min_cycles = cycles;
        if (cycles > max_cycles) max_cycles = cycles;
    }

    printf("  Marked count: %u (consistent across 100 runs)\n", ref_count);
    printf("  Cycles: min=%u max=%u jitter=%u\n",
           min_cycles, max_cycles, max_cycles - min_cycles);
    printf("  Result: %s\n", pass ? "PASS" : "FAIL");
    return pass;
}

// ============================================================
// 主函数
// ============================================================
int main(int argc, char **argv) {
    printf("╔════════════════════════════════════════════╗\n");
    printf("║  FOGCCC GC Coprocessor Test Suite          ║\n");
    printf("║  Platform: Xilinx Zynq-7000 XC7Z100        ║\n");
    printf("╚════════════════════════════════════════════╝\n");

    (void)argc; (void)argv;

    // 初始化FPGA
    fpga_gc_t dev;
    if (fpga_gc_init(&dev) < 0) {
        printf("\nFPGA initialization FAILED!\n");
        printf("Checklist:\n");
        printf("  1. Bitstream loaded?  cat /sys/class/fpga_manager/fpga0/state\n");
        printf("  2. Running as root?   sudo ./test_fpga\n");
        printf("  3. Address correct?   FPGA_BASE_ADDR in fpga_gc.h\n");
        return 1;
    }

    // 运行测试
    int pass1 = test_correctness(&dev);
    int pass2 = test_cycle(&dev);
    int pass3 = test_repeat(&dev);

    // 打印硬件统计
    fpga_gc_print_stats(&dev);

    // 汇总
    int all_pass = pass1 && pass2 && pass3;
    printf("\n");
    printf("=============================================\n");
    printf("  SUMMARY\n");
    printf("=============================================\n");
    printf("  Test 1 (Correctness) : %s\n", pass1 ? "PASS" : "FAIL");
    printf("  Test 2 (Cycle)       : %s\n", pass2 ? "PASS" : "FAIL");
    printf("  Test 3 (Repeat)      : %s\n", pass3 ? "PASS" : "FAIL");
    printf("  -------------------------------------------\n");
    printf("  Overall: %s\n", all_pass ? "*** ALL PASS ***" : "*** FAILED ***");
    printf("=============================================\n");

    fpga_gc_close(&dev);
    return all_pass ? 0 : 1;
}
